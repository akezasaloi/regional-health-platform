output "db_endpoint" {
  description = "MySQL hostname (Aiven). Does not include the port."
  value       = var.db_host
}

output "db_port" {
  description = "MySQL port (Aiven)."
  value       = var.db_port
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret that holds the DB envelope. Not the secret value."
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.db.name
}
