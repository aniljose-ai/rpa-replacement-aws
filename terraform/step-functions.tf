# ---------------------------------------------------------------------------
# Step Functions — Fan-Out Orchestrator
# Pattern: Query DynamoDB GSI → Map (fan-out) → ECS RunTask (waitForTaskToken)
# Idempotency: CheckIdempotency + MarkInProgress with ConditionalCheckFailed
# Optimistic locking: ConditionExpression on status prevents double-claim
# ---------------------------------------------------------------------------

locals {
  sfn_name = "rpa-replacement-${var.environment}-fan-out"
}

# --- CloudWatch Log Group ---
resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/${local.sfn_name}"
  retention_in_days = 14
}

# --- IAM Role ---
resource "aws_iam_role" "sfn_execution" {
  name = "${local.sfn_name}-ExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_policy" {
  name = "FanOutExecutionPolicy"
  role = aws_iam_role.sfn_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # DynamoDB — query via GSI
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = "${aws_dynamodb_table.automation_tasks.arn}/index/*"
      },
      # DynamoDB — per-item idempotency check and status updates
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.automation_tasks.arn
      },
      # ECS — launch Fargate tasks
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.automation.family}:*"
      },
      # IAM PassRole — allow SFN to pass roles to ECS
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.automation_task_role.arn, aws_iam_role.automation_execution_role.arn]
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM propagation delay — prevents SFN from using the role before it's fully active
resource "time_sleep" "sfn_role_propagation" {
  create_duration = "60s"
  depends_on = [
    aws_iam_role.sfn_execution,
    aws_iam_role_policy.sfn_policy
  ]
}

# --- State Machine ---
resource "aws_sfn_state_machine" "fan_out" {
  name     = local.sfn_name
  role_arn = aws_iam_role.sfn_execution.arn

  definition = jsonencode({
    Comment = "RPA Replacement — Fan-out: Query PENDING tasks, launch ECS Fargate per item with callback token"
    StartAt = "QueryPendingItems"
    States = {

      # Step 1: Query DynamoDB GSI for all PENDING tasks
      QueryPendingItems = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:dynamodb:query"
        Parameters = {
          TableName                = aws_dynamodb_table.automation_tasks.name
          IndexName                = "status-index"
          KeyConditionExpression   = "#status = :pending"
          ExpressionAttributeNames = { "#status" = "status" }
          ExpressionAttributeValues = {
            ":pending" = { "S" = "PENDING" }
          }
        }
        ResultPath = "$.queryResult"
        Next       = "CheckItemsExist"
      }

      # Short-circuit: nothing to do
      CheckItemsExist = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.queryResult.Count"
          NumericEquals = 0
          Next          = "NoItemsToProcess"
        }]
        Default = "ProcessBatch"
      }

      NoItemsToProcess = {
        Type    = "Succeed"
        Comment = "No PENDING tasks found — clean exit"
      }

      # Step 2: Fan-out — one ECS task per PENDING item
      ProcessBatch = {
        Type           = "Map"
        ItemsPath      = "$.queryResult.Items"
        MaxConcurrency = var.max_concurrency
        Iterator = {
          StartAt = "CheckIdempotency"
          States = {

            # Re-read item to get current status (avoids stale GSI reads)
            CheckIdempotency = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:getItem"
              Parameters = {
                TableName = aws_dynamodb_table.automation_tasks.name
                Key       = { task_id = { "S.$" = "$.task_id.S" } }
              }
              ResultPath = "$.current"
              Next       = "EvaluateStatus"
            }

            # Skip items already claimed or completed
            EvaluateStatus = {
              Type = "Choice"
              Choices = [
                {
                  Variable     = "$.current.Item.status.S"
                  StringEquals = "DONE"
                  Next         = "AlreadyProcessed"
                },
                {
                  Variable     = "$.current.Item.status.S"
                  StringEquals = "IN_PROGRESS"
                  Next         = "AlreadyProcessed"
                }
              ]
              Default = "MarkInProgress"
            }

            AlreadyProcessed = {
              Type    = "Succeed"
              Comment = "Idempotency guard — skip DONE or IN_PROGRESS items"
            }

            # Optimistic lock: claim the item only if still PENDING
            MarkInProgress = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:updateItem"
              Parameters = {
                TableName                = aws_dynamodb_table.automation_tasks.name
                Key                      = { task_id = { "S.$" = "$.task_id.S" } }
                ConditionExpression      = "#status = :pending"
                UpdateExpression         = "SET #status = :in_progress, executionArn = :arn, updatedAt = :ts"
                ExpressionAttributeNames = { "#status" = "status" }
                ExpressionAttributeValues = {
                  ":pending"     = { "S" = "PENDING" }
                  ":in_progress" = { "S" = "IN_PROGRESS" }
                  ":arn"         = { "S.$" = "$$.Execution.Id" }
                  ":ts"          = { "S.$" = "$$.State.EnteredTime" }
                }
              }
              Catch = [{
                ErrorEquals = ["DynamoDB.ConditionalCheckFailedException"]
                ResultPath  = "$.claimError"
                Next        = "AlreadyProcessed"
              }]
              ResultPath = null
              Next       = "RunECSTask"
            }

            # Launch Fargate task; worker reports completion via Step Functions callback
            RunECSTask = {
              Type             = "Task"
              Resource         = "arn:aws:states:::ecs:runTask.waitForTaskToken"
              HeartbeatSeconds = var.task_heartbeat_seconds
              TimeoutSeconds   = var.task_timeout_seconds
              Parameters = {
                Cluster        = aws_ecs_cluster.automation.name
                TaskDefinition = aws_ecs_task_definition.automation.family
                LaunchType     = "FARGATE"
                NetworkConfiguration = {
                  AwsvpcConfiguration = {
                    Subnets        = values(aws_subnet.automation_subnet)[*].id
                    SecurityGroups = [aws_security_group.automation_sg.id]
                    AssignPublicIp = "ENABLED"
                  }
                }
                Overrides = {
                  ContainerOverrides = [{
                    Name = local.automation_container_name
                    Environment = [
                      { "Name" = "TASK_ID", "Value.$" = "$.task_id.S" },
                      { "Name" = "JOBS_TABLE", "Value" = aws_dynamodb_table.automation_tasks.name },
                      { "Name" = "SFN_TASK_TOKEN", "Value.$" = "$$.Task.Token" },
                      { "Name" = "SFN_HEARTBEAT_SECONDS", "Value" = tostring(var.task_heartbeat_seconds) }
                    ]
                  }]
                }
              }
              Retry = [{
                ErrorEquals     = ["ECS.AmazonECSException", "ECS.ECSException"]
                IntervalSeconds = 30
                BackoffRate     = 2.0
                MaxAttempts     = 3
                JitterStrategy  = "FULL"
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "MarkFailed"
              }]
              ResultPath = "$.ecsResult"
              Next       = "MarkDone"
            }

            MarkDone = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:updateItem"
              Parameters = {
                TableName                = aws_dynamodb_table.automation_tasks.name
                Key                      = { task_id = { "S.$" = "$.task_id.S" } }
                UpdateExpression         = "SET #status = :done, updatedAt = :ts"
                ExpressionAttributeNames = { "#status" = "status" }
                ExpressionAttributeValues = {
                  ":done" = { "S" = "DONE" }
                  ":ts"   = { "S.$" = "$$.State.EnteredTime" }
                }
              }
              ResultPath = null
              End        = true
            }

            MarkFailed = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:updateItem"
              Parameters = {
                TableName                = aws_dynamodb_table.automation_tasks.name
                Key                      = { task_id = { "S.$" = "$.task_id.S" } }
                UpdateExpression         = "SET #status = :failed, errorMessage = :err, updatedAt = :ts"
                ExpressionAttributeNames = { "#status" = "status" }
                ExpressionAttributeValues = {
                  ":failed" = { "S" = "FAILED" }
                  ":err"    = { "S.$" = "States.Format('ECS task failed: {}', $.error.Cause)" }
                  ":ts"     = { "S.$" = "$$.State.EnteredTime" }
                }
              }
              ResultPath = null
              End        = true
            }
          }
        }
        End = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  depends_on = [
    aws_iam_role_policy.sfn_policy,
    aws_cloudwatch_log_group.sfn_logs,
    time_sleep.sfn_role_propagation
  ]
}
