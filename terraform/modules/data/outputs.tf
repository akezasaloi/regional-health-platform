output "db_endpoint" {
  description = "RDS instance hostname. Does not include the port."
  value       = aws_db_instance.mysql.address
}

output "db_port" {
  description = "RDS instance port."
  value       = aws_db_instance.mysql.port
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret that holds the DB envelope. Not the secret value."
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.db.name
}
