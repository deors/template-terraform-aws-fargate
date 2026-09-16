variable "name" {
  description = "Base name for all resources (used as prefix; keep short — ALB names have a 32-char limit)"
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging, prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# ── Networking ─────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "VPC ID where all resources will be created"
  type        = string
}

variable "app_subnet_ids" {
  description = "Private subnet IDs for ECS Fargate tasks (at least 2 AZs recommended)"
  type        = list(string)
}

variable "alb_subnet_ids" {
  description = "Subnet IDs for the ALB. Use public subnets for dev (internet-facing) and private for staging/prod (internal)"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "app_sg_id" {
  description = "Security group ID for ECS Fargate tasks"
  type        = string
}

variable "alb_internal" {
  description = "Set true for an internal (private) ALB (staging/prod). Set false for an internet-facing ALB (dev)."
  type        = bool
  default     = true
}

# ── Container image ────────────────────────────────────────────────────────

variable "container_image" {
  description = "Full container image reference (e.g. public.ecr.aws/nginx/nginx:stable-alpine)"
  type        = string
}

variable "container_port" {
  description = "TCP port the application container listens on"
  type        = number
  default     = 8080
}

# ── Task sizing ────────────────────────────────────────────────────────────

variable "task_cpu" {
  description = "Fargate task vCPU units (256=0.25vCPU, 512=0.5, 1024=1, 2048=2, 4096=4)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB (must be compatible with task_cpu)"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Desired number of running ECS tasks"
  type        = number
  default     = 1
}

# ── Application settings ───────────────────────────────────────────────────

variable "app_settings" {
  description = "Environment variables for the container (plain key-value). Do not put secrets here; use Secrets Manager references instead."
  type        = map(string)
  default     = {}
}

variable "secrets_manager_arns" {
  description = "Map of env-var name to Secrets Manager secret ARN. These are injected as container secrets (not environment variables), so values never appear in the task definition plaintext."
  type        = map(string)
  default     = {}
}

variable "registry_credentials_secret_arn" {
  description = "ARN of a Secrets Manager secret holding {\"username\": ..., \"password\": ...} for the container registry. Required for private registries other than ECR (e.g. GHCR); leave empty for anonymous or ECR pulls."
  type        = string
  default     = ""
}

variable "registry_credentials_kms_key_arn" {
  description = "KMS key ARN encrypting registry_credentials_secret_arn, when it is a customer-managed key (the execution role gets kms:Decrypt on it). Leave empty for the AWS-managed key."
  type        = string
  default     = ""
}

# ── Health check ───────────────────────────────────────────────────────────

variable "health_check_path" {
  description = "HTTP path the ALB target group health check polls"
  type        = string
  default     = "/health"
}

variable "health_check_grace_period_seconds" {
  description = "Seconds to ignore failed health checks after a task starts (grace for slow start-up)"
  type        = number
  default     = 60
}

# ── TLS / ALB ─────────────────────────────────────────────────────────────

variable "enable_https" {
  description = "Whether to create the HTTPS listener on port 443. Must be a plan-time-known value (not derived from a computed certificate ARN). Set to var.main_domain != \"\" in the environment config."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener. Only used when enable_https = true. May be a computed value (resolved at apply time)."
  type        = string
  default     = ""
}

variable "ssl_policy" {
  description = "ALB SSL policy for the HTTPS listener. Must be a TLS 1.3-only policy: the platform baseline requires TLS 1.3 in every environment, dev and staging included. Constrained by validation rather than left to the default alone, so a caller cannot silently weaken the listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-3-2021-06"

  # Allow-list, not a name pattern. The "TLS13" prefix is NOT a safety signal:
  # ELBSecurityPolicy-TLS13-1-0-2021-06 negotiates TLSv1 through TLSv1.3, and
  # ELBSecurityPolicy-TLS13-1-1-2021-06 starts at TLSv1.1 — a regex on "TLS13"
  # would happily admit both. Only the "-1-3-" family is TLS 1.3-exclusive.
  #
  # These are every policy whose SslProtocols is exactly ["TLSv1.3"], confirmed
  # against the eu-west-1 endpoint. Re-check before extending:
  #   aws elbv2 describe-ssl-policies --region <r> \
  #     --query 'SslPolicies[?SslProtocols==[`TLSv1.3`]].Name'
  validation {
    condition = contains([
      "ELBSecurityPolicy-TLS13-1-3-2021-06",              # baseline
      "ELBSecurityPolicy-TLS13-1-3-FIPS-2023-04",         # FIPS 140-3
      "ELBSecurityPolicy-TLS13-1-3-RFC9151-FIPS-2023-07", # RFC 9151 (CNSA) + FIPS
      "ELBSecurityPolicy-TLS13-1-3-PQ-2025-09",           # post-quantum hybrid KEM
      "ELBSecurityPolicy-TLS13-1-3-FIPS-PQ-2025-09",      # post-quantum + FIPS
    ], var.ssl_policy)
    error_message = "ssl_policy must be a TLS 1.3-only ALB policy (an ELBSecurityPolicy-TLS13-1-3-* variant). Policies that still negotiate TLS 1.2 or older violate the platform TLS baseline — note that ELBSecurityPolicy-TLS13-1-2-*, -TLS13-1-1-* and -TLS13-1-0-* all carry the TLS13 prefix but permit older protocols."
  }
}

# ── Auto Scaling ───────────────────────────────────────────────────────────

variable "enable_autoscaling" {
  description = "Enable Application Auto Scaling for the ECS service"
  type        = bool
  default     = false
}

variable "autoscale_min_count" {
  description = "Minimum number of ECS tasks when autoscaling is enabled"
  type        = number
  default     = 1
}

variable "autoscale_max_count" {
  description = "Maximum number of ECS tasks when autoscaling is enabled"
  type        = number
  default     = 3
}

variable "autoscale_cpu_target" {
  description = "Target CPU utilization (%) for autoscaling scale-out"
  type        = number
  default     = 70
}

variable "autoscale_memory_target" {
  description = "Target memory utilization (%) for autoscaling scale-out"
  type        = number
  default     = 80
}

# ── Blue/green deployment ──────────────────────────────────────────────────

variable "enable_blue_green" {
  description = "Enable CodeDeploy blue/green deployment for the ECS service"
  type        = bool
  default     = false
}

variable "codedeploy_deployment_config" {
  description = "CodeDeploy deployment config name for blue/green traffic shifting"
  type        = string
  default     = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
}

# ── Observability ──────────────────────────────────────────────────────────

variable "log_group_name" {
  description = "CloudWatch log group name for ECS container logs (from the monitoring module)"
  type        = string
}

variable "enable_xray" {
  description = "Enable AWS X-Ray daemon sidecar in the task definition"
  type        = bool
  default     = true
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights on the ECS cluster"
  type        = bool
  default     = true
}
