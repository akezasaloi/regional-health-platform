# Copy this directory to terraform/envs/<you>/ after modules/data and
# modules/service exist. Then:
#   cp ../../backend.example.hcl backend.hcl
#   # set key = "envs/<you>/terraform.tfstate"
#   tflocal init -backend-config=backend.hcl
#   make up TF_WHO=<you>
#
# Aiven connection values are never committed. `make up` maps AIVEN_* → TF_VAR_db_*.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    # filled by -backend-config=backend.hcl (see ../../backend.example.hcl)
  }
}

# tflocal injects LocalStack endpoints. On real AWS this file is unchanged;
# unset AWS_ENDPOINT_URL and drop tflocal for the official terraform binary.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
}

variable "app_ami_id" {
  type        = string
  description = "LocalStack EC2 AMI tag, form localstack-ec2/app:ami-<12hex>"
}

# Aiven MySQL (free plan). Pass via environment — never commit values:
#   TF_VAR_db_host / AIVEN_HOST, TF_VAR_db_port / AIVEN_PORT,
#   TF_VAR_db_password / AIVEN_PASSWORD. `make up` exports TF_VAR_* for you.
variable "db_host" {
  type        = string
  description = "Aiven MySQL hostname. Never commit."
}

variable "db_port" {
  type        = number
  description = "Aiven MySQL port (not 3306 on the free plan)."
}

variable "db_username" {
  type        = string
  description = "Aiven MySQL user."
  default     = "avnadmin"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Aiven MySQL password. Never commit."
}

variable "db_name" {
  type        = string
  description = "Logical database name stored in the Secrets Manager envelope."
  default     = "capacity_lab"
}

module "data" {
  source      = "../../modules/data"
  db_host     = var.db_host
  db_port     = var.db_port
  db_username = var.db_username
  db_password = var.db_password
  db_name     = var.db_name
}

module "service" {
  source      = "../../modules/service"
  app_ami_id  = var.app_ami_id
  secret_arn  = module.data.secret_arn
  db_endpoint = module.data.db_endpoint
  db_port     = module.data.db_port
}

output "db_endpoint" {
  value = module.data.db_endpoint
}

output "db_port" {
  value = module.data.db_port
}

output "secret_arn" {
  value     = module.data.secret_arn
  sensitive = true
}

output "instance_id" {
  value = module.service.instance_id
}

# Direct to EC2 public IP (ELBv2 removed — not on LocalStack Hobby license).
# Override with APP_URL if the output is not reachable from the host.
output "app_url" {
  value = "http://${module.service.app_host}:${module.service.app_port}"
}
