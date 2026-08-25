locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# CloudWatch Log Groups
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  # checkov:skip=CKV_AWS_158: KMS CMK for log group encryption is out of scope for this workshop template.
  # checkov:skip=CKV_AWS_338: Retention is environment-driven (30/60/90 days); 1-year minimum is a prod compliance decision, not a template default.
  name              = "/ecs/${local.prefix}"
  retention_in_days = var.log_retention_days
  tags              = local.base_tags
}

resource "aws_cloudwatch_log_group" "xray" {
  # checkov:skip=CKV_AWS_158: KMS CMK for log group encryption is out of scope for this workshop template.
  # checkov:skip=CKV_AWS_338: Retention is environment-driven (30/60/90 days); 1-year minimum is a prod compliance decision, not a template default.
  count             = var.enable_xray ? 1 : 0
  name              = "/ecs/${local.prefix}/xray"
  retention_in_days = var.log_retention_days
  tags              = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# X-Ray Sampling Rule
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_xray_sampling_rule" "this" {
  count = var.enable_xray ? 1 : 0

  rule_name      = "${local.prefix}-sampling"
  priority       = 9000
  version        = 1
  reservoir_size = 1
  fixed_rate     = var.xray_sampling_rate
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = local.prefix
  resource_arn   = "*"

  tags = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# CloudWatch Alarms
#
# Alarm dimensions reference the cluster/service names that the webapp module
# creates using the same prefix convention — no circular dependency needed.
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${local.prefix}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.alarm_cpu_threshold
  alarm_description   = "ECS CPU utilization above ${var.alarm_cpu_threshold}% for 2 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = local.prefix
    ServiceName = local.prefix
  }

  tags = local.base_tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  alarm_name          = "${local.prefix}-ecs-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.alarm_memory_threshold
  alarm_description   = "ECS memory utilization above ${var.alarm_memory_threshold}% for 2 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = local.prefix
    ServiceName = local.prefix
  }

  tags = local.base_tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_task_count_low" {
  alarm_name          = "${local.prefix}-ecs-task-count-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ECS running task count dropped below 1 for 2 minutes"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = local.prefix
    ServiceName = local.prefix
  }

  tags = local.base_tags
}
