# ---------------------------------------------------------------------------
# Secrets Manager — portal credentials injected into the ECS container
# Populate via AWS Console or CLI after first apply:
#   aws secretsmanager put-secret-value \
#     --secret-id <secret_arn> \
#     --secret-string '{"APP_USERNAME":"...","APP_PASSWORD":"..."}'
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "automation_credentials" {
  name                    = "${var.automation_name}/${var.environment}/automation-credentials"
  description             = "Portal login credentials for the ECS automation worker"
  recovery_window_in_days = 0 # allow immediate deletion on destroy (demo)

  tags = {
    project     = "rpa-replacement"
    environment = var.environment
  }
}

output "automation_credentials_secret_arn" {
  description = "ARN of the automation credentials secret — populate this before running the state machine"
  value       = aws_secretsmanager_secret.automation_credentials.arn
}
