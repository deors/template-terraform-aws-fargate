output "cluster_id" {
  description = "ID of the ECS cluster"
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.this.name
}

output "service_id" {
  description = "ID of the ECS service"
  value       = aws_ecs_service.this.id
}

output "service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "ARN of the ECS task definition"
  value       = aws_ecs_task_definition.this.arn
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.this.arn
}

output "alb_dns" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Route 53 hosted zone ID of the ALB (for alias records)"
  value       = aws_lb.this.zone_id
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution IAM role"
  value       = aws_iam_role.task_execution.arn
}

output "task_role_arn" {
  description = "ARN of the ECS task IAM role"
  value       = aws_iam_role.task.arn
}

output "codedeploy_app_name" {
  description = "Name of the CodeDeploy application (empty when blue/green is disabled)"
  value       = var.enable_blue_green ? aws_codedeploy_app.this[0].name : ""
}

output "codedeploy_deployment_group" {
  description = "Name of the CodeDeploy deployment group (empty when blue/green is disabled)"
  value       = var.enable_blue_green ? aws_codedeploy_deployment_group.this[0].deployment_group_name : ""
}

output "auth_user_pool_id" {
  description = "Cognito user pool ID backing ALB authentication (empty when disabled)"
  value       = try(aws_cognito_user_pool.this[0].id, "")
}

output "auth_sign_in_domain" {
  description = "Hostname of the Cognito hosted sign-in page (empty when disabled)"
  value       = try("${aws_cognito_user_pool_domain.this[0].domain}.auth.${data.aws_region.current.name}.amazoncognito.com", "")
}

output "auth_default_user_secret_arn" {
  description = "Secrets Manager secret holding the test user's credentials (empty when no test user)"
  value       = try(aws_secretsmanager_secret.default_user[0].arn, "")
}
