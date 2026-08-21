# LocalStack Hobby returns 501 for RDS. MySQL lives on Aiven; this module
# only wraps the connection envelope in Secrets Manager (C3). Same six keys
# so api/secrets.js and modules/service (DB_SECRET_ARN) stay valid.

resource "aws_secretsmanager_secret" "db" {
  name = var.secret_name
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "mysql"
    username = var.db_username
    password = var.db_password
    host     = var.db_host
    port     = var.db_port
    dbname   = var.db_name
  })
}
