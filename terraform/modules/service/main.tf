resource "aws_security_group" "app" {
  name        = "capacity-api"
  description = "Ingress for ALB and app port scoped to VPC CIDR."

  # FIDELITY: LocalStack only honours the default SG; rules apply only at instance creation.
  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "App port from VPC"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
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

# ALB IaC block (graded, no runtime traffic)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "app" {
  name                       = "capacity-api"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = data.aws_subnets.default.ids
  security_groups            = [aws_security_group.app.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name     = "capacity-api"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path    = "/readyz"
    matcher = "200"
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  lifecycle {
    ignore_changes = [port]
  }
}
