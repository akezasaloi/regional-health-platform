output "instance_id" {
  description = "EC2 instance ID running capacity-api."
  value       = aws_instance.app.id
}

output "sg_id" {
  description = "Security group attached to the app instance."
  value       = aws_security_group.app.id
}

output "app_host" {
  description = "EC2 public IP for reaching the app (ELBv2 dropped — not on LocalStack free tier)."
  value       = aws_instance.app.public_ip
}

output "app_port" {
  description = "Port the capacity-api container listens on."
  value       = var.app_port
}
