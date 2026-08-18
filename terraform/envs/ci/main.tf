# CI Terraform root. Committed (unlike the per-person envs/<you> dirs, which
# are created by hand from envs/_template) so the pipeline has a root to apply
# without a manual copy step.
#
# The backend is configured inline rather than via -backend-config=backend.hcl,
# because the Makefile's `up` target runs a bare `tflocal init`. Bucket and lock
# table are created by bootstrap/tfstate.sh before init runs.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    bucket         = "tfstate-regional-health"
    key            = "envs/ci/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tfstate-lock"
    encrypt        = true
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

# Supplied by CI as TF_VAR_app_ami_id, from the build-and-scan-image job output.
variable "app_ami_id" {
  type        = string
  description = "LocalStack EC2 AMI tag, form localstack-ec2/app:ami-<12hex>"
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the ALB HTTPS listener."
  default     = "arn:aws:acm:us-east-1:000000000000:certificate/localstack-stub"
}

module "data" {
  source = "../../modules/data"
}

module "service" {
  source          = "../../modules/service"
  app_ami_id      = var.app_ami_id
  secret_arn      = module.data.secret_arn
  db_endpoint     = module.data.db_endpoint
  db_port         = module.data.db_port
  certificate_arn = var.certificate_arn
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

output "app_url" {
  value = "http://${module.service.lb_dns_name}"
}
