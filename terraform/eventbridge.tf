# ---------------------------------------------------------------------------
# EventBridge Scheduler — triggers the Step Functions fan-out on a schedule
# Schedule expression is configurable via var.schedule_expression
# ---------------------------------------------------------------------------

resource "aws_scheduler_schedule_group" "automation" {
  name = "${var.automation_name}-${var.environment}"
}

resource "aws_scheduler_schedule" "automation_batch_sweep" {
  name       = "${var.automation_name}-${var.environment}-batch-sweep"
  group_name = aws_scheduler_schedule_group.automation.name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = var.schedule_expression

  target {
    arn      = aws_sfn_state_machine.fan_out.arn
    role_arn = aws_iam_role.scheduler_role.arn
    input    = jsonencode({})
  }
}

# --- IAM Role for EventBridge Scheduler ---
resource "aws_iam_role" "scheduler_role" {
  name = "${var.automation_name}-${var.environment}-Scheduler-ExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_start_sfn" {
  name = "StartAutomationStateMachine"
  role = aws_iam_role.scheduler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.fan_out.arn
    }]
  })
}
