output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (for ECS Fargate tasks and internal ALB)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (for NAT Gateway and internet-facing ALB in dev)"
  value       = aws_subnet.public[*].id
}

output "alb_sg_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "ID of the ECS app security group"
  value       = aws_security_group.app.id
}

output "private_zone_id" {
  description = "ID of the VPC-private hosted zone for the app FQDN. Empty string when not created (public-DNS environment, or main_domain not set)."
  value       = local.create_private_zone ? aws_route53_zone.private[0].zone_id : ""
}

output "private_zone_name" {
  description = "Name of the VPC-private hosted zone (the app FQDN). Empty string when not created."
  value       = local.create_private_zone ? aws_route53_zone.private[0].name : ""
}

output "certificate_arn" {
  description = "ARN of the ACM certificate issued for this environment. Empty string when main_domain is not set."
  value       = local.create_certificate ? aws_acm_certificate_validation.this[0].certificate_arn : ""
}

output "cert_domain_name" {
  description = "FQDN of the issued certificate (<name>.<environment>.<main_domain>). Empty string when main_domain is not set."
  value       = local.create_certificate ? local.cert_domain_name : ""
}

output "public_zone_id" {
  description = "Route 53 public hosted zone ID for main_domain. Empty string when main_domain is not set."
  value       = local.create_certificate ? data.aws_route53_zone.public[0].zone_id : ""
}
