output "alb_dns" {
  description = "DNS name of the Application Load Balancer"
  value       = module.webapp.alb_dns
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = module.webapp.cluster_name
}

output "service_name" {
  description = "ECS service name"
  value       = module.webapp.service_name
}

output "task_role_arn" {
  description = "ARN of the ECS task IAM role"
  value       = module.webapp.task_role_arn
}

output "log_group_name" {
  description = "CloudWatch log group for application logs"
  value       = module.monitoring.log_group_name
}
