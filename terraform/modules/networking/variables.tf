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

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Use non-overlapping ranges: dev=10.10.0.0/16, staging=10.20.0.0/16, prod=10.30.0.0/16"
  type        = string
  default     = "10.10.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (one per AZ, for ECS tasks and internal ALB)"
  type        = list(string)
  default     = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (one per AZ, for NAT Gateway and internet-facing ALB)"
  type        = list(string)
  default     = ["10.10.3.0/24", "10.10.4.0/24"]
}

variable "availability_zones" {
  description = "List of AZ names to spread subnets across. Defaults to first 2 AZs in the current region."
  type        = list(string)
  default     = []
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway for all private subnets (cost-saving for non-prod; set false for HA in prod)"
  type        = bool
  default     = true
}

variable "private_zone_name" {
  description = "Name for the Route 53 private hosted zone"
  type        = string
  default     = "internal"
}

variable "flow_log_retention_days" {
  description = "Retention period in days for VPC flow log CloudWatch group"
  type        = number
  default     = 30
}

variable "app_port" {
  description = "TCP port the application container listens on (used to configure the app security group)"
  type        = number
  default     = 8080
}

variable "main_domain" {
  description = "Root domain managed in Route 53 (e.g. \"example.com\"). When set, a DNS-validated ACM certificate is issued for <environment>-<name>.<main_domain> using the matching public hosted zone."
  type        = string
  default     = ""
}
