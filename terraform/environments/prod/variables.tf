variable "aws_region" {
  description = "AWS region for all resources (e.g. eu-west-1, us-east-1). No default — must be set explicitly to avoid accidental cross-region deployments."
  type        = string
}

variable "app_name" {
  description = "Application name (short, lowercase, no spaces). Used as a resource name prefix."
  type        = string
}

variable "container_image" {
  description = "Container image reference (repository/image:tag)"
  type        = string
}

variable "registry_credentials_secret_arn" {
  description = "Secrets Manager secret ARN with the registry credentials ({\"username\", \"password\"}); required for private registries other than ECR, empty for anonymous or ECR pulls"
  type        = string
  default     = ""
}

variable "registry_credentials_kms_key_arn" {
  description = "KMS key ARN of the registry credentials secret when it uses a customer-managed key; empty for the AWS-managed key"
  type        = string
  default     = ""
}

variable "container_port" {
  description = "TCP port the application container listens on (default 8080)"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "HTTP path the ALB health check polls (default /health)"
  type        = string
  default     = "/health"
}

variable "main_domain" {
  description = "Root domain managed in Route 53 (e.g. \"example.com\"). Certificate is issued for <app_name>.prod.<main_domain>."
  type        = string
}

variable "app_settings" {
  description = "Additional application environment variables"
  type        = map(string)
  default     = {}
}
