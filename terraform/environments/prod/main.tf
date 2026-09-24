locals {
  environment = "prod"

  common_tags = {
    application = var.app_name
    environment = local.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Monitoring
# ──────────────────────────────────────────────────────────────────────────────
module "monitoring" {
  source = "../../modules/monitoring"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  log_retention_days = 90

  # Prod: 1% sampling for low overhead at production traffic volumes
  enable_xray        = true
  xray_sampling_rate = 0.01
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  # Prod CIDR block: 10.30.0.0/16 (non-overlapping with dev/staging)
  vpc_cidr             = "10.30.0.0/16"
  private_subnet_cidrs = ["10.30.1.0/24", "10.30.2.0/24"]
  public_subnet_cidrs  = ["10.30.3.0/24", "10.30.4.0/24"]

  # Prod: one NAT GW per AZ for HA (no single point of failure)
  single_nat_gateway      = false
  flow_log_retention_days = 90

  app_port = var.container_port

  # ACM certificate: issued for <app_name>.prod.<main_domain> via DNS validation
  main_domain = var.main_domain

  # The ALB exchanges authentication tokens with the identity provider
  alb_egress_https = var.main_domain != ""

  # Prod's ALB is internal: publish the FQDN in a VPC-private hosted zone
  # (split-horizon), never in public DNS — a public record answering with
  # RFC1918 addresses leaks internal topology and is dropped by resolvers with
  # DNS-rebinding protection. Only the ACM validation CNAMEs stay public.
  private_app_dns = true
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App
# ──────────────────────────────────────────────────────────────────────────────
module "webapp" {
  source = "../../modules/webapp"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  # Networking: prod uses an internal ALB (private subnets), multi-AZ
  vpc_id         = module.networking.vpc_id
  app_subnet_ids = module.networking.private_subnet_ids
  alb_subnet_ids = module.networking.private_subnet_ids
  alb_sg_id      = module.networking.alb_sg_id
  app_sg_id      = module.networking.app_sg_id
  alb_internal   = true

  container_image                  = var.container_image
  registry_credentials_secret_arn  = var.registry_credentials_secret_arn
  registry_credentials_kms_key_arn = var.registry_credentials_kms_key_arn
  container_port                   = var.container_port

  # Prod: large Fargate size — sized for sustained production traffic
  task_cpu    = 1024
  task_memory = 2048

  # Prod: autoscale 3-10 tasks; minimum 3 ensures cross-AZ spread
  desired_count           = 3
  enable_autoscaling      = true
  autoscale_min_count     = 3
  autoscale_max_count     = 10
  autoscale_cpu_target    = 70
  autoscale_memory_target = 80

  # TLS 1.3 enforced in all environments per company policy (module validates this).
  # enable_https must be a plan-time value — var.main_domain != "" is always known at plan time.
  enable_https    = var.main_domain != ""
  certificate_arn = module.networking.certificate_arn
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-3-2021-06"

  # Prod: mandatory CodeDeploy blue/green, linear 10% traffic shift for safe rollout
  enable_blue_green            = true
  codedeploy_deployment_config = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"

  app_settings = var.app_settings

  # Authentication at the ALB, active whenever HTTPS is (requires main_domain);
  # one non-interactive test user per environment, password in Secrets Manager
  enable_auth       = var.main_domain != ""
  app_fqdn          = module.networking.cert_domain_name
  auth_default_user = "demo"

  log_group_name            = module.monitoring.log_group_name
  enable_xray               = true
  enable_container_insights = true

  health_check_grace_period_seconds = 120

  health_check_path = var.health_check_path
}

# ──────────────────────────────────────────────────────────────────────────────
# DNS — alias record pointing the app FQDN at the internal ALB, at the apex of
# the VPC-private hosted zone. The name resolves only inside the VPC; outside
# it does not resolve at all, which is the point.
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_route53_record" "alb" {
  count   = var.main_domain != "" ? 1 : 0
  zone_id = module.networking.private_zone_id
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
