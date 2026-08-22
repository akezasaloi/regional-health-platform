# C5 — gates that actually block

Three tools, three deliberately red PRs, then a fix commit each. A scanner
that runs but never fails the build is theatre.

| Gate | Red PR | Scanner output | Fix commit |
|---|---|---|---|
| gitleaks | fake `MYSQL_ROOT_PASSWORD` in tracked config (+ enabled `useDefault`) | [#20](https://github.com/akezasaloi/regional-health-platform/pull/20) · [failed run](https://github.com/akezasaloi/regional-health-platform/actions/runs/32557113201) | [PR #21](https://github.com/akezasaloi/regional-health-platform/pull/21) · [`1576bc8`](https://github.com/akezasaloi/regional-health-platform/commit/1576bc8b7797127d6c7a6c731faf42be983908b2) |
| trivy config | SSH ingress (port 22) open to `0.0.0.0/0` | [#22](https://github.com/akezasaloi/regional-health-platform/pull/22) · [failed run](https://github.com/akezasaloi/regional-health-platform/actions/runs/32562633515) | [`2d2de18`](https://github.com/akezasaloi/regional-health-platform/commit/2d2de187d7f634fc9f15a0c7cf4cd712756c6554) |
| zizmor | one `uses:` moved from a 40-char SHA to `@v4` | _PR link_ | _sha_ |

Scanner output for each is committed alongside this file: `trivy-image.json`,
`trivy-config.json`, `zizmor.txt`.

## What each gate does **not** catch

Knowing the limits of a green check is the point of this section.

**gitleaks** matches patterns that *look like* credentials — high-entropy
strings, known token shapes. It cannot tell that a legitimate-looking value is
live, and it will not flag a password that looks like ordinary prose
(`hunter2`, a passphrase, a base64 blob it has no rule for). It also says
nothing about whether a secret is *appropriate*: a correctly-stored ARN pointing
at an over-permissioned secret passes cleanly. Green means "no known pattern
matched", not "no secrets here".

**trivy** compares declared configuration and installed package versions against
databases of known issues. **`AVD-AWS-0107` only flags SSH (22) and RDP (3389)
ingress to `0.0.0.0/0`** — widening the app port to the whole internet did not
fail the gate; adding an SSH ingress rule did. It cannot reason about runtime: a
security group that trivy passes may still be wide open because LocalStack only
honours the default SG, and a `0.0.0.0/0` egress rule it flags may be entirely
correct for a NAT-less build box. On images it only knows *published* CVEs — a
vulnerability disclosed tomorrow is invisible today, and our scan runs
`ignore-unfixed`, so ~48 HIGH/CRITICAL findings with no upstream patch are
reported but do not block. Green means "nothing known and fixable", not
"secure".

**zizmor** analyses workflow files statically: unpinned actions, script
injection through `${{ }}` in `run:`, over-broad `permissions`, inherited
secrets. It cannot see *inside* the action it is telling you to pin. A SHA-pinned
action whose code is malicious at that exact commit passes every check — which
is precisely the tj-actions/changed-files failure mode, where tags were
repointed at attacker-controlled code. Pinning defeats tag mutation, not a
compromised maintainer or a zero-day in the tool itself.

## Guard the guards

Pinning is necessary and not sufficient, so the pipeline layers containment and
detection on top of prevention:

- **Integrity** — every `uses:` is a 40-char commit SHA and the container base
  is pinned by digest (`api/Dockerfile`). Bumps arrive as reviewed Dependabot
  PRs ([`dependabot.yml`](../../.github/dependabot.yml)), never `@latest`. The
  `zizmor` step itself is pinned to an exact version for the same reason.
- **Blast radius** — the four scanner jobs run `permissions: contents: read`
  with no `secrets:` block and no `AIVEN_*` or `LOCALSTACK_AUTH_TOKEN` in scope.
  A compromised scanner cannot exfiltrate what its job was never given. Only
  `deploy-and-verify` receives credentials.
- **Detection** — `step-security/harden-runner` runs as the first step of every
  job in egress-audit mode, so a step phoning home to an unexpected host is
  visible after the fact. You cannot prevent an unknown zero-day; you contain it
  and you notice it.
- **Locally** — [`.githooks/pre-commit`](../../.githooks/pre-commit) runs
  gitleaks over staged content before a secret can become a commit. Enable with
  `git config core.hooksPath .githooks`. History rewriting is the expensive
  cure; the commit is the point of no return, not the push.
