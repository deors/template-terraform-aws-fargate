locals {
  environment = "staging"

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

  log_retention_days = 60

  # Staging: 10% sampling to match realistic prod-like traffic volume
  enable_xray        = true
  xray_sampling_rate = 0.10
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  # Staging CIDR block: 10.20.0.0/16 (non-overlapping with dev/prod)
  vpc_cidr             = "10.20.0.0/16"
  private_subnet_cidrs = ["10.20.1.0/24", "10.20.2.0/24"]
  public_subnet_cidrs  = ["10.20.3.0/24", "10.20.4.0/24"]

  single_nat_gateway      = true
  flow_log_retention_days = 60

  app_port = var.container_port

  # ACM certificate: issued for staging-<app_name>.<main_domain> via DNS validation
  main_domain = var.main_domain
}

# ──────────────────────────────────────────────────────────────────────────────
# Web App
# ──────────────────────────────────────────────────────────────────────────────
module "webapp" {
  source = "../../modules/webapp"

  name        = var.app_name
  environment = local.environment
  tags        = local.common_tags

  # Networking: staging uses an internal ALB (private subnets)
  vpc_id         = module.networking.vpc_id
  app_subnet_ids = module.networking.private_subnet_ids
  alb_subnet_ids = module.networking.private_subnet_ids
  alb_sg_id      = module.networking.alb_sg_id
  app_sg_id      = module.networking.app_sg_id
  alb_internal   = true

  container_image = var.container_image
  container_port  = var.container_port

  # Staging: medium Fargate size — prod-readiness testing
  task_cpu    = 512
  task_memory = 1024

  # Staging: autoscale 1-3 tasks
  desired_count           = 1
  enable_autoscaling      = true
  autoscale_min_count     = 1
  autoscale_max_count     = 3
  autoscale_cpu_target    = 70
  autoscale_memory_target = 80

  # TLS 1.3 enforced in all environments per company policy (module validates this).
  # enable_https must be a plan-time value — var.main_domain != "" is always known at plan time.
  enable_https    = var.main_domain != ""
  certificate_arn = module.networking.certificate_arn
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-3-2021-06"

  # Staging: optional CodeDeploy blue/green, linear 10% traffic shift
  enable_blue_green            = true
  codedeploy_deployment_config = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"

  app_settings = var.app_settings

  log_group_name            = module.monitoring.log_group_name
  enable_xray               = true
  enable_container_insights = true

  health_check_path = var.health_check_path
}

# ──────────────────────────────────────────────────────────────────────────────
# DNS — alias record pointing the app FQDN at the ALB
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
