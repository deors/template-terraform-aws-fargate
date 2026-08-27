locals {
  environment = "dev"

  common_tags = {
    application = var.app_name
    environment = local.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring (CloudWatch log groups, X-Ray, alarms)
# ──────────────────────────────────────────────────────────────────────────────
module "monitoring" {
  source = "../../modules/monitoring"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  log_retention_days = 30

  # Dev: capture 100% of traces for full observability during development
  enable_xray        = true
  xray_sampling_rate = 1.0
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking (VPC, subnets, security groups, Route 53)
# ──────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  # Dev CIDR block: 10.10.0.0/16 (non-overlapping with staging/prod)
  vpc_cidr             = "10.10.0.0/16"
  private_subnet_cidrs = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnet_cidrs  = ["10.10.3.0/24", "10.10.4.0/24"]

  # Single NAT Gateway is sufficient for dev (cost-saving)
  single_nat_gateway = true

  flow_log_retention_days = 30

  app_port = var.container_port

  # ACM certificate: issued for <app_name>.dev.<main_domain> via DNS validation
  main_domain = var.main_domain
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App (ECS Fargate, ALB, IAM)
# ──────────────────────────────────────────────────────────────────────────────
module "webapp" {
  source = "../../modules/webapp"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  # Networking: dev uses a public (internet-facing) ALB so GitHub-hosted runners
  # can reach the app for HTTP smoke tests without needing VPN or private runners.
  # Staging and prod use an internal ALB instead.
  vpc_id         = module.networking.vpc_id
  app_subnet_ids = module.networking.private_subnet_ids
  alb_subnet_ids = module.networking.public_subnet_ids
  alb_sg_id      = module.networking.alb_sg_id
  app_sg_id      = module.networking.app_sg_id
  alb_internal   = false

  container_image = var.container_image
  container_port  = var.container_port

  # Dev: smallest Fargate size — fast iteration, low cost
  task_cpu    = 256
  task_memory = 512

  # Dev: fixed single task, no autoscaling
  desired_count      = 1
  enable_autoscaling = false

  # TLS 1.3 enforced in all environments per company policy (module validates this).
  # enable_https must be a plan-time value — var.main_domain != "" is always known at plan time.
  enable_https    = var.main_domain != ""
  certificate_arn = module.networking.certificate_arn
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-3-2021-06"

  # Dev: rolling deployment (no CodeDeploy), faster iteration
  enable_blue_green = false

  app_settings = var.app_settings

  # Observability
  log_group_name            = module.monitoring.log_group_name
  enable_xray               = true
  enable_container_insights = true

  health_check_path = var.health_check_path
}

# ──────────────────────────────────────────────────────────────────────────────
# DNS — alias record pointing the app FQDN at the ALB
# Created only when main_domain is set; omitted for plain HTTP-only deployments.
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_route53_record" "alb" {
  count   = var.main_domain != "" ? 1 : 0
  zone_id = module.networking.public_zone_id
  name    = module.networking.cert_domain_name
  type    = "A"

  alias {
    name                   = module.webapp.alb_dns
    zone_id                = module.webapp.alb_zone_id
    evaluate_target_health = true
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Resource Group — all resources for this app/environment in one view
# Tag-based query: matches every resource tagged with application + environment
# + platform. All modules apply these tags via their base_tags local.
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_resourcegroups_group" "this" {
  name        = "rg-${var.app_name}-${local.environment}"
  description = "All ${var.app_name} resources deployed to the ${local.environment} environment"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        { Key = "application", Values = [var.app_name] },
        { Key = "environment", Values = [local.environment] },
        { Key = "platform", Values = ["platform-engineering"] },
      ]
    })
  }

  tags = local.common_tags
}
