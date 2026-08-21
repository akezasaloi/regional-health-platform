# Aiven seed path (C2)

`ROW_COUNT` is a documented variable, not a hardcoded 100k.

LocalStack Hobby has no RDS. The restore target is **Aiven MySQL** (free plan).

| Path | Rows | Target |
|---|---|---|
| `docker compose exec ... seed.sh` | 100000 (default) | local `mysql-db` (A1) |
| `scripts/seed.sh` / `make seed` | **10000** | Aiven via `mysqldump \| mysql` over TLS (A2) |

`01-fixes.sql` (last_name index from OPS-2201) is applied to the dump
source before `mysqldump`, so Aiven gets the fixed schema.

Credentials are read from Secrets Manager (Terraform wrote the Aiven envelope
there). Set `AIVEN_CA_PATH` to the CA file from the Aiven console for
`VERIFY_CA`; otherwise the client uses `--ssl-mode=REQUIRED`.

Wake the service first if it has been idle — free-plan MySQL sleeps.
