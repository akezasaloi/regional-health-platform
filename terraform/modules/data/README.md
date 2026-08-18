# data module — RDS MySQL + Secrets Manager

Provisions the Regional Health database plane for LocalStack (C1/C2/C3-envelope).

- `random_password.db` generates a 24-char password (`special = false`) used by **both** RDS and the secret, so they cannot drift.
- `aws_db_instance.mysql` is MySQL 8.0, `db.t3.micro`, 20 GiB gp3, not publicly accessible, `storage_encrypted = true` (trivy-config). LocalStack echoes that flag and does not encrypt.
- `aws_secretsmanager_secret.db` stores the connection envelope under `regional-health/db`. Keys are exactly `engine`, `username`, `password`, `host`, `port`, `dbname` — the app reads these names.
- Outputs are `db_endpoint`, `db_port`, `secret_arn`, `secret_name`. The password and `secret_string` are never outputted.

Call from `terraform/envs/<who>/` as `module "data" { source = "../../modules/data" }`.

## Who reads the secret

The secret value is never an output. Consumers:

- **`modules/service` (PR-B)** — EC2 user-data gets `DB_SECRET_ARN` (the ARN only, never the password).
- **`api/secrets.js` (individual env PRs)** — `GetSecretValue` at boot. Envelope keys are exactly `engine`, `username`, `password`, `host`, `port`, `dbname`.

No IAM principal is attached in this module. Lab/LocalStack uses static test credentials (`AWS_ACCESS_KEY_ID=test`). On real AWS the instance profile of `aws_instance.app` would be granted `secretsmanager:GetSecretValue` on `secret_arn`. LocalStack IMDS does not reliably serve `iam/security-credentials/` (FIDELITY).

Rotation is out of scope: the password is generated once at apply and written to RDS and Secrets Manager together so they cannot drift.
