variable "db_name" {
  type        = string
  description = "Logical MySQL database name stored in the Secrets Manager envelope."
  default     = "capacity_lab"
}

variable "db_username" {
  type        = string
  description = "MySQL username. Aiven Hobby uses avnadmin."
  default     = "avnadmin"
}

variable "db_host" {
  type        = string
  description = "Aiven MySQL hostname. This module does not provision the database."
}

variable "db_port" {
  type        = number
  description = "Aiven MySQL port."
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Aiven MySQL password. Stored in Secrets Manager, never outputted."
}

variable "secret_name" {
  type        = string
  description = "Secrets Manager secret name that holds the DB connection envelope."
  default     = "regional-health/db"
}
