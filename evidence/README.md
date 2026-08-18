# Evidence bundle (Assignment 2)

A1 artifacts in this folder stay where they are. A2 evidence uses the numbered
tree below. **No artifact, no credit.** Screenshots only where nothing else
works (Grafana panels). Keep committed evidence small.

```
evidence/
  01-iac/            apply.log  plan-after-apply.txt (must be empty)  destroy.log
  02-data/           seed.log  row-counts.txt
  03-secrets/        gitleaks.json  image-env.txt  user-data.txt  boot.log
  04-health/         readyz-degraded.txt
  05-gates/          README.md (3 red-PR links)  trivy-image.json  trivy-config.json  zizmor.txt
  06-observability/  alert-rules.yml  dashboards/  panels/
  07-incidents/      2201/  2202/  2203/  2204/
```

Highest-signal artifacts:
- `04-health/readyz-degraded.txt` — break the secret, `/readyz` flips 503, recover
- `05-gates/README.md` — three PRs that went **red**, then the fix commit
