variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "automation_name" {
  description = "Short name for the automation (used in resource naming)"
  type        = string
}

variable "table_name" {
  description = "Name of the DynamoDB automation_tasks table"
  type        = string
  default     = "automation_tasks"
}

variable "max_concurrency" {
  description = "Maximum concurrent ECS tasks in the Map fan-out"
  type        = number
  default     = 10
}

variable "task_timeout_seconds" {
  description = "Per-task timeout for RunECSTask state (seconds)"
  type        = number
  default     = 3600
}

variable "task_heartbeat_seconds" {
  description = "Heartbeat timeout for the waitForTaskToken ECS task state (seconds)"
  type        = number
  default     = 300
}

variable "headless" {
  description = "Run the browser automation in headless mode"
  type        = bool
  default     = true
}

variable "dry_run" {
  description = "Dry-run mode — log actions without submitting"
  type        = bool
  default     = false
}

variable "schedule_expression" {
  description = "EventBridge schedule expression for the batch sweep (e.g. 'rate(5 minutes)', 'cron(0 6 * * ? *)')"
  type        = string
  default     = "rate(5 minutes)"
}
