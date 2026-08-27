locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })

  # Resolve AZs: use provided list or fall back to data source
  azs = length(var.availability_zones) > 0 ? var.availability_zones : data.aws_availability_zones.available.names

  # Number of subnets = number of provided CIDRs (must match across private/public)
  subnet_count = length(var.private_subnet_cidrs)

  # ACM certificate automation: active only when main_domain is provided
  create_certificate = var.main_domain != ""
  cert_domain_name   = "${lower(var.name)}.${lower(var.environment)}.${var.main_domain}"

  # Split-horizon DNS: a VPC-private zone for the app FQDN, for environments
  # whose ALB is internal (see the Route 53 section below)
  create_private_zone = local.create_certificate && var.private_app_dns
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ──────────────────────────────────────────────────────────────────────────────
# VPC
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.base_tags, { Name = "vpc-${local.prefix}" })
}

# Restrict the default security group so no traffic flows through it by default
# (CKV2_AWS_12). All workloads use explicit security groups defined below.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "sg-default-restricted-${local.prefix}" })
}

# ──────────────────────────────────────────────────────────────────────────────
# Subnets
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = local.subnet_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index % length(local.azs)]

  map_public_ip_on_launch = false

  tags = merge(local.base_tags, {
    Name = "snet-private-${local.prefix}-${count.index + 1}"
    Type = "private"
  })
}

resource "aws_subnet" "public" {
  count = local.subnet_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index % length(local.azs)]

  map_public_ip_on_launch = false

  tags = merge(local.base_tags, {
    Name = "snet-public-${local.prefix}-${count.index + 1}"
    Type = "public"
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# Internet Gateway
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "igw-${local.prefix}" })
}

# ──────────────────────────────────────────────────────────────────────────────
# NAT Gateway (for ECS task outbound traffic to ECR, AWS APIs, etc.)
# single_nat_gateway=true (default): one NAT GW for cost efficiency in dev/staging
# single_nat_gateway=false: one NAT GW per AZ for HA in prod
# ──────────────────────────────────────────────────────────────────────────────

locals {
  nat_count = var.single_nat_gateway ? 1 : local.subnet_count
}

resource "aws_eip" "nat" {
  # checkov:skip=CKV2_AWS_19: EIP is attached to NAT GW which is not in the checkov model as "EC2 instance"
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(local.base_tags, { Name = "eip-nat-${local.prefix}-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.base_tags, { Name = "nat-${local.prefix}-${count.index + 1}" })

  depends_on = [aws_internet_gateway.this]
}

# ──────────────────────────────────────────────────────────────────────────────
# Route Tables
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "rt-public-${local.prefix}" })
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.subnet_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = local.subnet_count
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "rt-private-${local.prefix}-${count.index + 1}" })
}

resource "aws_route" "private_nat" {
  count = local.subnet_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = local.subnet_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ──────────────────────────────────────────────────────────────────────────────
# Security Groups
# ──────────────────────────────────────────────────────────────────────────────

# ALB security group: HTTPS inbound from internet (or VPC for internal ALB), app port outbound to app SG
resource "aws_security_group" "alb" {
  # checkov:skip=CKV_AWS_260: ALB must accept HTTPS from the internet in dev (public endpoint). Staging/prod use internal ALB with no public inbound.
  # checkov:skip=CKV2_AWS_5: SG is associated with the ALB resource created in the webapp module.
  name        = "alb-sg-${local.prefix}"
  description = "Security group for the Application Load Balancer"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from internet (dev public ALB) or VPC (internal ALB)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP for redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound to app containers on the app port"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.base_tags, { Name = "alb-sg-${local.prefix}" })
}

# App (ECS task) security group: accept inbound from ALB only, restrict outbound to AWS services
resource "aws_security_group" "app" {
  # checkov:skip=CKV2_AWS_5: SG is associated with the ECS service created in the webapp module.
  name        = "app-sg-${local.prefix}"
  description = "Security group for ECS Fargate tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Inbound from ALB on app port only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # HTTPS outbound to AWS services (ECR, Secrets Manager, CloudWatch, etc.)
  egress {
    description = "HTTPS to AWS services"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS resolution, scoped to the VPC.
  #
  # Traffic to the default resolver (Route 53 Resolver at VPC-base+2 /
  # 169.254.169.253) bypasses security group evaluation entirely — AWS does
  # not let SGs filter it — so tasks resolve names regardless of these rules.
  # What this scope governs is the non-default path: a container querying an
  # external resolver directly. Restricting it to the VPC CIDR closes the
  # direct-to-internet DNS channel (the classic DNS-tunnelling exfiltration
  # path) at zero cost to standard workloads, while keeping the rules as
  # documentation of intent and cover for any future in-VPC resolver.
  egress {
    description = "DNS (UDP) for name resolution, VPC-scoped"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # DNS over TCP (fallback for truncated responses, e.g. large record sets)
  egress {
    description = "DNS (TCP) fallback, VPC-scoped"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.base_tags, { Name = "app-sg-${local.prefix}" })
}

# ──────────────────────────────────────────────────────────────────────────────
# Route 53 Private Hosted Zone — split-horizon DNS for internal environments
#
# Created only when a certificate is issued AND the app's DNS is private
# (private_app_dns, set for environments whose ALB is internal). The zone is
# named after the app FQDN itself, so the alias record at its apex matches the
# ACM certificate and HTTPS hostname verification works unchanged inside the
# VPC. The environment root creates that record — it needs the ALB attributes
# from the webapp module, which this module cannot reference.
#
# Why internal ALBs must not use a public record: a world-resolvable record
# answering with RFC1918 addresses leaks internal topology, and resolvers with
# DNS-rebinding protection drop such answers, making the name intermittently
# unresolvable for legitimate clients depending on their DNS path. The public
# zone keeps only the ACM validation CNAMEs, which must stay public for
# issuance and renewal. The FQDN's existence is public regardless — every ACM
# certificate lands in Certificate Transparency logs — but the IPs are not.
#
# A .internal-style zone cannot serve this purpose: no public CA issues
# certificates for reserved TLDs, so any name under it fails TLS verification.
resource "aws_route53_zone" "private" {
  count = local.create_private_zone ? 1 : 0
  name  = local.cert_domain_name

  vpc {
    vpc_id = aws_vpc.this.id
  }

  tags = merge(local.base_tags, { Name = "zone-${local.prefix}" })
}

# ──────────────────────────────────────────────────────────────────────────────
# VPC Flow Logs → CloudWatch
# ──────────────────────────────────────────────────────────────────────────────

# name_prefix, not name, and deliberately so.
#
# VPC Flow Logs delivery is buffered and asynchronous. On destroy, Terraform
# deletes this log group and then the flow log, but AWS's delivery service can
# flush a buffered batch afterwards — and when the destination group is gone it
# recreates it, with no retention policy. Observed on this template: the group
# reappeared six seconds into a destroy, leaving an orphan that Terraform no
# longer tracked. The next apply then failed with ResourceAlreadyExistsException
# on a fixed name, so every destroy poisoned the following apply.
#
# A generated suffix means each apply gets a name that cannot already exist.
# skip_destroy does not help here: it keeps the group but still drops it from
# state, so the next apply tries to create it and hits the same conflict.
#
# Trade-off: an orphaned group may linger per destroy. They hold no data (the
# recreated group receives nothing once the flow log is gone) and log groups
# themselves are not billed, so this is clutter rather than cost. Nothing
# depends on the literal name — the IAM policy and the flow log reference the
# ARN, and verify.sh locates flow logs by VPC id.
resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_158: KMS CMK for flow log encryption is out of scope for this workshop template.
  # checkov:skip=CKV_AWS_338: Retention is environment-driven (30/60/90 days); 1-year minimum is a prod compliance decision, not a template default.
  name_prefix       = "/vpc/flow-logs/${local.prefix}-"
  retention_in_days = var.flow_log_retention_days
  tags              = local.base_tags
}

resource "aws_iam_role" "flow_logs" {
  name = "role-flow-logs-${local.prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "flow-logs-cw-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = merge(local.base_tags, { Name = "flowlog-${local.prefix}" })
}

# ──────────────────────────────────────────────────────────────────────────────
# ACM Certificate (DNS-validated via Route 53)
# Issued for <name>.<environment>.<main_domain> when main_domain is provided.
# The validation resource blocks apply until ACM reports ISSUED, so the
# certificate_arn output is safe to use immediately in the webapp module.
# ──────────────────────────────────────────────────────────────────────────────

data "aws_route53_zone" "public" {
  count        = local.create_certificate ? 1 : 0
  name         = var.main_domain
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  count             = local.create_certificate ? 1 : 0
  domain_name       = local.cert_domain_name
  validation_method = "DNS"

  tags = merge(local.base_tags, { Name = "cert-${local.prefix}" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.create_certificate ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => dvo
  } : {}

  zone_id         = data.aws_route53_zone.public[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.create_certificate ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
