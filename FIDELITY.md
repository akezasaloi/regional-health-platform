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

## <caveat 1>
- **What LocalStack did:**
- **How I detected it:**
- **What I'd verify on real AWS:**

## <caveat 2>
- **What LocalStack did:**
- **How I detected it:**
- **What I'd verify on real AWS:**
