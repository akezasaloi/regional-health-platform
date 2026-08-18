# C5 — gates that actually block

Three tools, three deliberately red PRs, then a fix commit each. A scanner
that runs but never fails the build is theatre.

| Gate | Red PR | Scanner output | Fix commit |
|---|---|---|---|
| gitleaks | _link_ | `gitleaks.json` (this folder, from the red run) | _sha_ |
| trivy config | _link_ | `trivy-config.json` | _sha_ |
| zizmor | _link_ | `zizmor.txt` | _sha_ |

## What each gate does NOT catch

- **gitleaks:** secrets below its entropy/rule threshold, and credentials that
  never enter git (chat, screenshots, the Terraform state file).
- **trivy config:** runtime drift (a security group edited after apply) and
  LocalStack ignoring custom SGs entirely.
- **zizmor:** a malicious commit already at a pinned SHA, a compromised
  maintainer, or a zero-day in the action's own logic — pin +
  `permissions: contents: read` + `harden-runner` egress audit contain and
  detect; they do not prevent an unknown compromise.
