output "log_group_name" {
  description = "Name of the CloudWatch log group for ECS application logs"
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group for ECS application logs"
  value       = aws_cloudwatch_log_group.app.arn
}

output "xray_log_group_name" {
  description = "Name of the CloudWatch log group for X-Ray daemon logs (empty when X-Ray is disabled)"
  value       = var.enable_xray ? aws_cloudwatch_log_group.xray[0].name : ""
}

output "alarm_cpu_arn" {
  description = "ARN of the ECS CPU high-utilization alarm"
  value       = aws_cloudwatch_metric_alarm.ecs_cpu_high.arn
}

output "alarm_memory_arn" {
  description = "ARN of the ECS memory high-utilization alarm"
  value       = aws_cloudwatch_metric_alarm.ecs_memory_high.arn
}

output "alarm_task_count_arn" {
  description = "ARN of the ECS low-task-count alarm"
  value       = aws_cloudwatch_metric_alarm.ecs_task_count_low.arn
}
