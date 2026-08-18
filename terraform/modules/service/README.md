# service — EC2 + nginx + ALB

Terraform module that runs the capacity-api on EC2 and declares an Application Load Balancer for health checks.

## Inputs

- `app_ami_id` (required) — LocalStack AMI tag, e.g. `localstack-ec2/app:ami-<12hex>`
- `secret_arn`, `db_endpoint` — wired from `module.data` (C4); password never in user-data
- `certificate_arn` (required) — ACM cert for the internal ALB HTTPS listener
- `instance_type`, `db_port`, `app_port`, `vpc_cidr` — optional with sensible defaults

## Outputs

`instance_id`, `sg_id`, `lb_dns_name` — consumed by `terraform/envs/<user>` for `app_url` and verify.

## Notes

Security group ingress/egress is scoped to `vpc_cidr`, not `0.0.0.0/0`. ALB is internal (graded IaC only, no runtime traffic). Target group health check uses `/readyz`.
