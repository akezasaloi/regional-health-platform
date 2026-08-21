# service — EC2 capacity-api

Terraform module that runs the capacity-api on LocalStack EC2. ELBv2 (ALB) was removed — it 501s on the LocalStack Hobby license, same as RDS.

## Inputs

- `app_ami_id` (required) — LocalStack AMI tag, e.g. `localstack-ec2/app:ami-<12hex>`
- `secret_arn`, `db_endpoint` — wired from `module.data` (C4); password never in user-data
- `instance_type`, `db_port`, `app_port`, `vpc_cidr` — optional with sensible defaults

## Outputs

`instance_id`, `sg_id`, `app_host`, `app_port` — consumed by `terraform/envs/<user>` for `app_url` and verify.

## Notes

Security group ingress/egress is scoped to `vpc_cidr`, not `0.0.0.0/0`. Health checks hit the app on the instance (`/healthz`, `/readyz`) via `app_url`, not through an ALB.
