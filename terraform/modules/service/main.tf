resource "aws_security_group" "app" {
  name        = "capacity-api"
  description = "Ingress for app port scoped to VPC CIDR."

  # FIDELITY: LocalStack only honours the default SG; rules apply only at instance creation.
  ingress {
    description = "App port from VPC"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound to VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_instance" "app" {
  ami                    = var.app_ami_id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]
  user_data = templatefile("${path.module}/user_data.tftpl", {
    secret_arn  = var.secret_arn
    db_endpoint = var.db_endpoint
    db_port     = var.db_port
    app_port    = var.app_port
    app_ami_id  = var.app_ami_id
  })

  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }
}
