# FIDELITY.md — where the emulator lied to you

For each behaviour LocalStack did **not** reproduce faithfully: how you detected
it, and what you'd have to verify in a real AWS account before trusting it. This
is the most transferable thing in the lab — not trusting your test environment is
a senior skill. Fill each with a real detection method, not a guess.

Starters you will hit (verify each yourself, do not just copy):

- only the `default` security group is honoured; custom SGs govern nothing
- SG ingress rules apply only at instance creation
- IMDS has no `iam/security-credentials/` endpoint
- `storage_encrypted` on RDS is returned as configured but not applied
- the Docker socket is mounted inside the EC2 "instance" (sibling container)
- ELBv2 health checking is undocumented; the listener port round-trips oddly
- declared instance classes (`db.t3.micro`, `t3.small`) are IaC only — LocalStack
  does not enforce vCPU/RAM; the Codespace is the real hardware

## RDS `aws_db_instance` is unlicensed on LocalStack Hobby (501)

- **What LocalStack did:** `tflocal apply` of `aws_db_instance.mysql` returned HTTP `501` — RDS is not in the Hobby license. The API accepted the resource in config/plan but refused to create it. `storage_encrypted` was also only echoed, never enforced.
- **How I detected it:** CI / `make up` failed on the data module with `501` from the LocalStack RDS API. Confirmed by removing `aws_db_instance` and seeing apply proceed past RDS.
- **What I'd verify on real AWS:** `CreateDBInstance` succeeds, storage encryption is actually on (`aws rds describe-db-instances` → `StorageEncrypted: true`), and the instance is not publicly accessible. In this lab MySQL is Aiven; Secrets Manager still holds the same six-key envelope so the app path matches real AWS.

## <caveat 2>
- **What LocalStack did:**
- **How I detected it:**
- **What I'd verify on real AWS:**
