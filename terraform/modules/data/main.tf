resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_instance" "mysql" {
  engine              = "mysql"
  engine_version      = var.engine_version
  instance_class      = var.instance_class
  allocated_storage   = var.allocated_storage
  storage_type        = "gp3"
  db_name             = var.db_name
  username            = var.db_username
  password            = random_password.db.result
  skip_final_snapshot = true
  publicly_accessible = false
  storage_encrypted = true
}

resource "aws_secretsmanager_secret" "db" {
  name = var.secret_name
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "mysql"
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.mysql.address
    port     = aws_db_instance.mysql.port
    dbname   = var.db_name
  })
}
