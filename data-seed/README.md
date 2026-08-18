# RDS seed path (C2)

`ROW_COUNT` is a documented variable, not a hardcoded 100k.

| Path | Rows | Target |
|---|---|---|
| `docker compose exec ... seed.sh` | 100000 (default) | local `mysql-db` (A1) |
| `scripts/seed.sh` / `make seed` | **10000** | LocalStack RDS via mysqldump restore (A2) |

`01-fixes.sql` (last_name index from OPS-2201) is applied to the dump
source before `mysqldump`, so RDS gets the fixed schema.
