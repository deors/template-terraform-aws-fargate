locals {
  prefix = lower("${var.name}-${var.environment}")

  base_tags = merge(var.tags, {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "platform-engineering"
  })

  # Whether to create HTTPS listener. Driven by enable_https (a plan-time boolean),
  # not by certificate_arn, because certificate_arn may be a computed value that
  # OpenTofu cannot evaluate at plan time — which would make the count unknowable.
  create_https_listener = var.enable_https

  # CodeDeploy requires two target groups; rolling uses one
  create_green_tg = var.enable_blue_green

  # Container environment variables merged with observability defaults
  container_env = merge(
    {
      PORT        = tostring(var.container_port)
      ENVIRONMENT = var.environment
    },
    var.app_settings,
  )

  # Secrets Manager secret references for the container definition
  container_secrets = [
    for name, arn in var.secrets_manager_arns : {
      name      = name
      valueFrom = arn
    }
  ]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# IAM – Task Execution Role
# Used by ECS to pull images from ECR and write logs to CloudWatch.
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "task_execution" {
  name = "ecs-exec-${local.prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Grant task execution role access to Secrets Manager so container secrets
# (var.secrets_manager_arns) can be injected at task launch time.
resource "aws_iam_role_policy" "task_execution_secrets" {
  count = length(var.secrets_manager_arns) > 0 ? 1 : 0
  name  = "secrets-access"
  role  = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = values(var.secrets_manager_arns)
    }]
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# IAM – Task Role
# Assumed by the running container for AWS SDK calls (Secrets Manager,
# X-Ray, etc.). Follows least-privilege; no admin or wildcard actions.
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "task" {
  name = "ecs-task-${local.prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy" "task_secrets_read" {
  name = "secrets-read"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${local.prefix}/*"
    }]
  })
}

resource "aws_iam_role_policy" "task_xray" {
  count = var.enable_xray ? 1 : 0
  name  = "xray-write"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets",
        "xray:GetSamplingStatisticSummaries",
      ]
      Resource = "*"
    }]
  })
}

# ──────────────────────────────────────────────────────────────────────────────
# ECS Cluster
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "this" {
  name = local.prefix

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = local.base_tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# ECS Task Definition
# ──────────────────────────────────────────────────────────────────────────────

locals {
  # X-Ray daemon sidecar — added to the task when enable_xray is true.
  # The daemon listens on localhost:2000 (UDP) within the awsvpc task network.
  xray_container = var.enable_xray ? [{
    name      = "xray-daemon"
    image     = "public.ecr.aws/xray/aws-xray-daemon:latest"
    essential = false
    cpu       = 32
    memory    = 64
    portMappings = [{
      containerPort = 2000
      protocol      = "udp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "${var.log_group_name}/xray"
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "xray"
      }
    }
  }] : []

  app_container = [{
    name      = var.name
    image     = var.container_image
    essential = true
    cpu       = var.task_cpu - (var.enable_xray ? 32 : 0)
    memory    = var.task_memory - (var.enable_xray ? 64 : 0)
    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]
    # Base env vars plus, when the X-Ray sidecar is enabled, the daemon
    # address within the task (awsvpc: localhost).
    environment = concat(
      [for k, v in local.container_env : { name = k, value = v }],
      var.enable_xray ? [{ name = "AWS_XRAY_DAEMON_ADDRESS", value = "localhost:2000" }] : [],
    )
    secrets = local.container_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = var.log_group_name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }]
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode(concat(local.app_container, local.xray_container))

  tags = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Application Load Balancer
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "this" {
  # checkov:skip=CKV_AWS_91: ALB access logs require a dedicated S3 bucket; logging is covered by CloudWatch and out of scope for this workshop template.
  # checkov:skip=CKV2_AWS_28: WAF integration is out of scope for this workshop template.
  name               = "alb-${local.prefix}"
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.alb_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"

  tags = local.base_tags
}

# Blue target group (primary; always created)
resource "aws_lb_target_group" "blue" {
  # checkov:skip=CKV_AWS_378: ALB→container traffic uses HTTP inside the VPC; TLS terminates at the ALB (end-to-end encryption from client to ALB).
  name_prefix = "tgb-"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-299"
  }

  tags = local.base_tags
}

# Green target group (CodeDeploy blue/green only)
resource "aws_lb_target_group" "green" {
  # checkov:skip=CKV_AWS_378: ALB→container traffic uses HTTP inside the VPC; TLS terminates at the ALB (end-to-end encryption from client to ALB).
  count = local.create_green_tg ? 1 : 0

  name_prefix = "tgg-"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-299"
  }

  tags = local.base_tags
}

# HTTPS listener (when certificate_arn is provided)
resource "aws_lb_listener" "https" {
  count = local.create_https_listener ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  tags = local.base_tags

  lifecycle {
    # CodeDeploy shifts traffic by modifying listener rules; ignore drift
    ignore_changes = [default_action]
  }
}

# HTTP listener: redirect to HTTPS when cert is present, forward directly otherwise (dev HTTP-only)
resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_103: HTTP listener is for redirect-to-HTTPS only; TLS cannot apply to an HTTP redirect listener.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.create_https_listener ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.create_https_listener ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.blue.arn
    }
  }

  tags = local.base_tags

  lifecycle {
    ignore_changes = [default_action]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# ECS Service
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_service" "this" {
  name            = local.prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_controller {
    type = var.enable_blue_green ? "CODE_DEPLOY" : "ECS"
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.name
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = var.health_check_grace_period_seconds

  lifecycle {
    # CodeDeploy owns task_definition and load_balancer after initial deployment
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  depends_on = [
    aws_lb_listener.https,
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.task_execution_managed,
  ]

  tags = local.base_tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Application Auto Scaling
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "this" {
  count = var.enable_autoscaling ? 1 : 0

  max_capacity       = var.autoscale_max_count
  min_capacity       = var.autoscale_min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscale_cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.prefix}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscale_memory_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# CodeDeploy Blue/Green
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "codedeploy" {
  count = var.enable_blue_green ? 1 : 0
  name  = "role-codedeploy-${local.prefix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.base_tags
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  count      = var.enable_blue_green ? 1 : 0
  role       = aws_iam_role.codedeploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "this" {
  count            = var.enable_blue_green ? 1 : 0
  name             = "cd-${local.prefix}"
  compute_platform = "ECS"

  tags = local.base_tags
}

resource "aws_codedeploy_deployment_group" "this" {
  count                  = var.enable_blue_green ? 1 : 0
  app_name               = aws_codedeploy_app.this[0].name
  deployment_group_name  = "${local.prefix}-dg"
  service_role_arn       = aws_iam_role.codedeploy[0].arn
  deployment_config_name = var.codedeploy_deployment_config

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.this.name
    service_name = aws_ecs_service.this.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = local.create_https_listener ? [aws_lb_listener.https[0].arn] : [aws_lb_listener.http.arn]
      }
      target_group {
        name = aws_lb_target_group.blue.name
      }
      target_group {
        name = aws_lb_target_group.green[0].name
      }
    }
  }

  tags = local.base_tags
}
