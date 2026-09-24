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

output "codedeploy_app_name" {
  description = "CodeDeploy application name"
  value       = module.webapp.codedeploy_app_name
}

output "codedeploy_deployment_group" {
  description = "CodeDeploy deployment group name"
  value       = module.webapp.codedeploy_deployment_group
}

output "auth_user_pool_id" {
  description = "Cognito user pool ID backing ALB authentication (empty when disabled)"
  value       = module.webapp.auth_user_pool_id
}

output "auth_sign_in_domain" {
  description = "Hostname of the Cognito hosted sign-in page (empty when disabled)"
  value       = module.webapp.auth_sign_in_domain
}

output "auth_default_user_secret_arn" {
  description = "Secrets Manager secret holding the test user's credentials (empty when no test user)"
  value       = module.webapp.auth_default_user_secret_arn
}
