output "table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.automation_tasks.name
}

output "table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.automation_tasks.arn
}

output "gsi_name" {
  description = "Name of the status GSI"
  value       = "status-index"
}

output "state_machine_arn" {
  description = "ARN of the fan-out Step Functions state machine"
  value       = aws_sfn_state_machine.fan_out.arn
}

output "sfn_role_arn" {
  description = "ARN of the Step Functions execution IAM role"
  value       = aws_iam_role.sfn_execution.arn
}
