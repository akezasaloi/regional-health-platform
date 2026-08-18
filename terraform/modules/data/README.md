# data module — RDS MySQL + Secrets Manager

Provisions the Regional Health database plane for LocalStack (C1/C2/C3-envelope).

- `random_password.db` generates a 24-char password (`special = false`) used by **both** RDS and the secret, so they cannot drift.
- `aws_db_instance.mysql` is MySQL 8.0, `db.t3.micro`, 20 GiB gp3, not publicly accessible, `storage_encrypted = true` (trivy-config). LocalStack echoes that flag and does not encrypt.
- `aws_secretsmanager_secret.db` stores the connection envelope under `regional-health/db`. Keys are exactly `engine`, `username`, `password`, `host`, `port`, `dbname` — the app reads these names.
- Outputs are `db_endpoint`, `db_port`, `secret_arn`, `secret_name`. The password and `secret_string` are never outputted.

Call from `terraform/envs/<who>/` as `module "data" { source = "../../modules/data" }`.
