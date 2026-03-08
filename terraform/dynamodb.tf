resource "aws_dynamodb_table" "automation_tasks" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key = "task_id"

  attribute {
    name = "task_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    project     = "rpa-replacement"
    environment = var.environment
  }
}
