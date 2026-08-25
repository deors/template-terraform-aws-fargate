variable "name" {
  description = "Base name for all resources (used as prefix)"
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

variable "log_retention_days" {
  description = "Retention period in days for CloudWatch log groups (30, 60, or 90)"
  type        = number
  default     = 30
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch Logs retention value."
  }
}

variable "enable_xray" {
  description = "Enable AWS X-Ray distributed tracing"
  type        = bool
  default     = true
}

variable "xray_sampling_rate" {
  description = "X-Ray sampling rate as a decimal fraction (0.0–1.0). dev=1.0, staging=0.10, prod=0.01"
  type        = number
  default     = 1.0
  validation {
    condition     = var.xray_sampling_rate >= 0.0 && var.xray_sampling_rate <= 1.0
    error_message = "xray_sampling_rate must be between 0.0 and 1.0."
  }
}

variable "alarm_cpu_threshold" {
  description = "ECS CPU utilization (%) threshold for the high-CPU alarm"
  type        = number
  default     = 70
}

variable "alarm_memory_threshold" {
  description = "ECS memory utilization (%) threshold for the high-memory alarm"
  type        = number
  default     = 80
}
