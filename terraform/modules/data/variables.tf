variable "db_name" {
  type        = string
  description = "Name of the MySQL database created on the RDS instance."
  default     = "capacity_lab"
}

variable "db_username" {
  type        = string
  description = "Master username for the RDS instance. Stored in Secrets Manager, never in outputs."
  default     = "app"
}

variable "instance_class" {
  type        = string
  description = "RDS instance class. db.t3.micro is the smallest class LocalStack round-trips."
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  type        = number
  description = "Allocated storage in GiB."
  default     = 20
}

variable "engine_version" {
  type        = string
  description = "MySQL engine version."
  default     = "8.0"
}

variable "secret_name" {
  type        = string
  description = "Secrets Manager secret name that holds the DB connection envelope."
  default     = "regional-health/db"
}
