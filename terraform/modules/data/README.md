# data module — Aiven MySQL envelope in Secrets Manager

Wraps an **external** Aiven MySQL connection in AWS Secrets Manager on LocalStack (C3). Does not provision RDS.

LocalStack Hobby returns `501` for `aws_db_instance` (RDS not licensed). The database is Aiven; this module only stores the connection envelope.

- Envelope keys are exactly `engine`, `username`, `password`, `host`, `port`, `dbname` — the app reads these names. **The secret contract did not change.**
- `db_username` defaults to `avnadmin`. `db_host`, `db_port`, and `db_password` (`sensitive = true`) are required — pass them from `terraform/envs/<who>/` / `AIVEN_*`.
- Outputs are `db_endpoint`, `db_port`, `secret_arn`, `secret_name`. The password and `secret_string` are never outputted.

Call from `terraform/envs/<who>/`:

```hcl
module "data" {
  source      = "../../modules/data"
  db_host     = var.db_host
  db_port     = var.db_port
  db_username = var.db_username
  db_password = var.db_password
}
```

## Who reads the secret

The secret value is never an output. Consumers:

- **`modules/service`** — EC2 user-data gets `DB_SECRET_ARN` (the ARN only, never the password).
- **`api/secrets.js`** — `GetSecretValue` at boot.

No IAM principal is attached in this module. Lab/LocalStack uses static test credentials (`AWS_ACCESS_KEY_ID=test`). On real AWS the instance profile of `aws_instance.app` would be granted `secretsmanager:GetSecretValue` on `secret_arn`.

Rotation is out of scope: the password is the Aiven credential passed in at apply, written once to Secrets Manager.
