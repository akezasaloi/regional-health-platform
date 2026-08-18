output "instance_id" {
  description = "EC2 instance ID running capacity-api."
  value       = aws_instance.app.id
}

output "sg_id" {
  description = "Security group attached to the app instance and ALB."
  value       = aws_security_group.app.id
}

output "lb_dns_name" {
  description = "DNS name of the application load balancer."
  value       = aws_lb.app.dns_name
}
