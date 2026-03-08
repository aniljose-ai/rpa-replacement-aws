# ---------------------------------------------------------------------------
# CodeBuild — Docker image build + ECR push for automation worker
# Pattern: archive source → S3 → CodeBuild (Linux) → ECR
# Triggered by Terraform on apply whenever source content changes (MD5 hash)
# ---------------------------------------------------------------------------

# Detect whether terraform apply is running on Windows or Unix.
# pathexpand("~") returns C:\Users\... on Windows and /home/... or /Users/... on Unix.
locals {
  is_windows = substr(pathexpand("~"), 0, 1) != "/"
}

# --- Zip project source (docker/ + root files, excluding infra noise) ---
data "archive_file" "automation_source" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/.terraform/automation_source.zip"

  excludes = [
    ".git/**",
    ".terraform/**",
    "terraform/**",
    "archive/**",
    "*.zip",
    "**/__pycache__/**",
    "**/.pytest_cache/**",
    "**/.venv/**",
    "**/venv/**"
  ]
}

# --- Upload source zip to S3 (key includes MD5 so new content = new object) ---
resource "aws_s3_object" "automation_source" {
  bucket = aws_s3_bucket.s3_bucket.id
  key    = "build-source/automation_source_${data.archive_file.automation_source.output_md5}.zip"
  source = data.archive_file.automation_source.output_path
  etag   = data.archive_file.automation_source.output_md5
}

# --- IAM Role for CodeBuild ---
resource "aws_iam_role" "automation_codebuild" {
  name = "${var.automation_name}-${var.environment}-automation-CodeBuildRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "automation_codebuild_policy" {
  name = "AutomationCodeBuildPolicy"
  role = aws_iam_role.automation_codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.automation_name}-${var.environment}-*"
        ]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = ["${aws_s3_bucket.s3_bucket.arn}/*"]
      },
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- CodeBuild: Linux worker image ---
resource "aws_codebuild_project" "automation_linux" {
  name          = "${var.automation_name}-${var.environment}-automation-linux-build"
  description   = "Build Linux automation worker Docker image for ${var.automation_name}-${var.environment}"
  service_role  = aws_iam_role.automation_codebuild.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.automation.name
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.s3_bucket.id}/${aws_s3_object.automation_source.key}"
    buildspec = file("${path.module}/../buildspec.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.automation_name}-${var.environment}-automation-linux-build"
    }
  }
}

# --- Trigger: start Linux build on apply, poll until complete ---
resource "null_resource" "automation_trigger_build" {
  depends_on = [
    aws_codebuild_project.automation_linux,
    aws_s3_object.automation_source
  ]

  triggers = {
    source_code_md5 = data.archive_file.automation_source.output_md5
  }

  provisioner "local-exec" {
    interpreter = local.is_windows ? ["PowerShell", "-Command"] : ["/bin/bash", "-c"]
    command     = local.is_windows ? "${path.module}/scripts/build-image.ps1 -ProjectName ${aws_codebuild_project.automation_linux.name} -Region ${var.region}" : "${path.module}/scripts/build-image.sh ${aws_codebuild_project.automation_linux.name} ${var.region}"
  }
}
