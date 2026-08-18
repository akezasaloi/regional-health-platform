variable "app_ami_id" {
  type        = string
  description = "LocalStack EC2 AMI tag (localstack-ec2/app:ami-<12hex>)."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the capacity API."
  default     = "t3.small"
}

variable "secret_arn" {
  type        = string
  description = "Secrets Manager ARN for the RDS credential envelope (C4 wiring)."
}

variable "db_endpoint" {
  type        = string
  description = "RDS hostname from module.data."
}

variable "db_port" {
  type        = number
  description = "RDS port."
  default     = 3306
}

variable "app_port" {
  type        = number
  description = "Port the capacity-api container listens on."
  default     = 3000
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR for security group ingress (never 0.0.0.0/0)."
  default     = "10.0.0.0/16"
}
