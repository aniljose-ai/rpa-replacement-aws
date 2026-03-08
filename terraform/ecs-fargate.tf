# ---------------------------------------------------------------------------
# Automation ECS Resources
# Pattern: ECR → ECS Fargate cluster + task definition + IAM roles
# Networking resources are in vpc.tf
# ---------------------------------------------------------------------------

locals {
  automation_cluster        = "${var.automation_name}-${var.environment}-automation"
  automation_task_family    = "${var.automation_name}-${var.environment}-automation-task"
  automation_container_name = "${var.automation_name}-automation"
  automation_task_role_name = "${var.automation_name}-${var.environment}-automation-TaskRole"
  cloudwatch_log_retention  = 14
}

# --- ECR Repository ---
resource "aws_ecr_repository" "automation" {
  name                 = lower("${var.automation_name}-${var.environment}-automation")
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "automation" {
  repository = aws_ecr_repository.automation.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- ECS Cluster ---
resource "aws_ecs_cluster" "automation" {
  name = local.automation_cluster

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "automation" {
  cluster_name = aws_ecs_cluster.automation.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# --- ECS Task Role (permissions used by the container code) ---
resource "aws_iam_role" "automation_task_role" {
  name = local.automation_task_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "automation_task_role_policy" {
  name = "AutomationTaskPolicy"
  role = aws_iam_role.automation_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.automation_tasks.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.s3_bucket.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess", "states:SendTaskFailure", "states:SendTaskHeartbeat"]
        Resource = "*"
      }
    ]
  })
}

# --- ECS Execution Role (used by ECS agent to start the container) ---
resource "aws_iam_role" "automation_execution_role" {
  name = "${var.automation_name}-${var.environment}-automation-ExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "automation_execution_role_managed" {
  role       = aws_iam_role.automation_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "automation_execution_role_secrets" {
  name = "AutomationSecretsAccess"
  role = aws_iam_role.automation_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.automation_credentials.arn
    }]
  })
}

# --- CloudWatch Log Group for ECS task output ---
resource "aws_cloudwatch_log_group" "automation_logs" {
  name              = "/ecs/${local.automation_task_family}"
  retention_in_days = local.cloudwatch_log_retention
}

# --- ECS Task Definition ---
resource "aws_ecs_task_definition" "automation" {
  family                   = local.automation_task_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.automation_execution_role.arn
  task_role_arn            = aws_iam_role.automation_task_role.arn

  depends_on = [null_resource.automation_trigger_build]

  container_definitions = jsonencode([{
    name      = local.automation_container_name
    image     = "${aws_ecr_repository.automation.repository_url}:latest"
    essential = true

    environment = [
      { name = "HEADLESS", value = tostring(var.headless) },
      { name = "DRY_RUN", value = tostring(var.dry_run) },
      { name = "ARTIFACTS_BUCKET", value = aws_s3_bucket.s3_bucket.bucket },
      { name = "PORTAL_BASE_URL", value = "https://vb-bank-demo.vercel.app/login" }
    ]

    secrets = [
      { name = "APP_PASSWORD", valueFrom = "${aws_secretsmanager_secret.automation_credentials.arn}:APP_PASSWORD::" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.automation_logs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}
