# Regional Health — Reliability On-Call Lab 🧪

A hands-on "Lab-in-a-Box" for learning **database mechanics, performance tuning,
and capacity engineering** the way you actually learn them on the job: by picking
up an incident ticket, reproducing the symptom, and investigating until you find
the root cause.

You are the on-call engineer for the **Regional Health** platform — a healthcare
API backed by MySQL. There is an [incident queue](./incidents/README.md) of open
tickets. Each ticket is a symptom report from a user or another team. **No ticket
tells you the cause, and there is no answer key in this repo.** You diagnose it
from evidence: query plans, connection behaviour, locks, and memory, observed
through Prometheus and Grafana.

> This is a training environment seeded with realistic data and realistic
> problems. Treat it like production you've just been handed.

---

## The environment

| Component        | Tech                  | Port  | Role                                  |
|------------------|-----------------------|-------|---------------------------------------|
| `capacity-api`   | Node.js + Express     | 3000  | The application under investigation   |
| `mysql-db`       | MySQL 8.0             | 3306  | Primary relational store              |
| `mongo-db`       | MongoDB 6.0           | 27017 | Audit store                           |
| `prometheus`     | Prometheus            | 9090  | Metrics scraping                      |
| `grafana`        | Grafana               | 3001  | Dashboards                            |
| load generator   | k6                    | —     | Reproduces each incident's traffic    |

---

## Quick start (3 steps)

### 1. Start the environment
```bash
docker compose up -d --build
```
Wait ~30–60s for MySQL to become healthy (`docker compose ps`).

### 2. Seed realistic data (100,000 patients, 5 hospitals)
The seed script runs *inside* the API container:
```bash
docker compose exec capacity-api bash /usr/local/bin/seed.sh
```

### 3. Open the dashboards
- **Grafana:**    http://localhost:3001  (user `admin` / pass `admin`; anonymous admin is also enabled)
- **Prometheus:** http://localhost:9090
- **API health:** http://localhost:3000/health
- **API metrics:** http://localhost:3000/metrics

In Grafana, add Prometheus as a data source at `http://prometheus:9090`, then
chart `http_request_duration_seconds`, `http_requests_total`,
`db_errors_total`, and `nodejs_heap_size_used_bytes`. Suggested queries are in
[`LAB_JOURNAL.md`](./LAB_JOURNAL.md).

---

## Your job: work the incident queue

Open **[`incidents/README.md`](./incidents/README.md)** and pick a ticket.

The general loop for every incident:

1. **Baseline** the healthy system so you have a control group:
   ```bash
   k6 run load-tests/00-baseline.js
   ```
2. **Reproduce** the reported symptom using that ticket's script, e.g.:
   ```bash
   k6 run load-tests/reproduce-OPS-2201.js
   ```
   (Each `reproduce-OPS-XXXX.js` recreates the *traffic pattern* from ticket
   `OPS-XXXX` — it does not tell you the cause.)
3. **Investigate** with the tools below while the load runs.
4. **Diagnose, fix, and re-run** to prove the fix.
5. **Write it up** in [`LAB_JOURNAL.md`](./LAB_JOURNAL.md).

> No installed k6? Run it in Docker (Linux host networking):
> ```bash
> docker run --rm -i --network host grafana/k6 run - < load-tests/reproduce-OPS-2201.js
> ```

---

## Investigation toolbox

```bash
# Follow the application logs (crashes, errors, restarts)
docker compose logs -f capacity-api

# Live memory / CPU / restart counts per container
docker stats

# Open a MySQL shell to inspect plans, locks, and schema
docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab
```

Inside the MySQL shell, techniques worth knowing:
`EXPLAIN ANALYZE <query>`, `SHOW CREATE TABLE <t>`, `SHOW ENGINE INNODB STATUS`,
and the `performance_schema` / `sys` views for locking. Which ones matter for a
given ticket is part of the exercise.

---

## Teardown
```bash
docker compose down -v
```

---

## Assignment 2 — rehost on LocalStack + Aiven MySQL

Linux only (use the Codespace: ⋯ → Change machine type → **4-core / 16 GB**).
Docker Desktop on macOS cannot reach LocalStack's EC2 containers.

LocalStack Hobby does **not** include RDS or ECR. The managed database is
[Aiven MySQL](https://aiven.io) (free plan, no credit card). The image is built
and scanned in CI and used directly — no registry. Everything else is unchanged:
Secrets Manager, EC2, scanning gates, pipeline.

### Aiven (about 5 minutes, personal account — one free MySQL per account)

1. Sign up at [aiven.io](https://aiven.io). No credit card.
2. Create a MySQL service on the **Free** plan. Wait until it is running.
3. Copy host, port, user (`avnadmin`), and password. Download the CA certificate.
4. Put them in your **local environment** and in **GitHub Actions secrets**. Never git.

```bash
export LOCALSTACK_AUTH_TOKEN=...          # Hobby token from app.localstack.cloud
export AIVEN_HOST=mysql-….a.aivencloud.com
export AIVEN_PORT=…                       # not 3306
export AIVEN_USER=avnadmin
export AIVEN_PASSWORD=…                   # never commit
export AIVEN_DB=capacity_lab
export AIVEN_CA_PATH=./secrets/aiven-ca.pem   # optional; VERIFY_CA if set

cp -R terraform/envs/_template terraform/envs/$USER
make up TF_WHO=$USER
make verify
make down
```

The free service **sleeps when idle** — open it in the Aiven console (or hit it
once) before `make up`. Limits (1 GB storage, 76 connections) are enough for
10k patients.

GitHub Actions secrets (same names, for Arsema's pipeline):
`LOCALSTACK_AUTH_TOKEN`, `AIVEN_HOST`, `AIVEN_PORT`, `AIVEN_USER`,
`AIVEN_PASSWORD`, `AIVEN_DB`.

### Declared sizes

| Resource | Value | Why |
|---|---|---|
| Aiven MySQL | Free plan (1 GB, 76 connections) | instructor: real managed MySQL; LocalStack RDS is paid |
| Seed size | 10,000 patients | C2; fits in 1 GB with room to spare |
| EC2 instance type | `t3.small` (2 vCPU / 2 GiB) | headroom for nginx + app; `t3.micro` is too tight |
| App container memory | `--memory=512m` | cgroup ceiling that makes OPS-2204 OOM reproducible |

`ROW_COUNT` for the cloud seed is **10000** (C2). Local compose still defaults to 100000.

See `terraform/README.md`, `CONTRIBUTIONS.md`, and `FIDELITY.md`.

---

## Deploy identity: OIDC instead of long-lived keys (E2)

CI holds no AWS keys in the production design. The deploy job mints a
short-lived GitHub OIDC token and exchanges it for a role via
`sts:AssumeRoleWithWebIdentity`. The commented `configure-aws-credentials`
block sits in `.github/workflows/ci.yml`; the trust policy is
[`docs/oidc-trust-policy.json`](docs/oidc-trust-policy.json). It is not enabled
in this lab because LocalStack accepts `test`/`test` and there is no real
account to federate against.

The whole security of the arrangement rests on one condition:

```json
"token.actions.githubusercontent.com:sub":
  "repo:akezasaloi/regional-health-platform:ref:refs/heads/main"
```

### What breaks if `sub` is `repo:<org>/*`

That wildcard says *"any workflow, in any repository in this org, on any ref,
may assume this role."* Three things break, in increasing order of severity.

**1. Every branch becomes production.** `ref:refs/heads/main` is what ties the
credential to reviewed code. Drop it and any branch can assume the role — and
anyone who can push a branch can push a workflow file. Opening a PR that adds
`.github/workflows/evil.yml` is then enough to read your production secrets, no
review required. Branch protection does not help: the workflow runs *before*
anything merges.

**2. Every repository in the org becomes production.** A wildcard over `<org>/*`
means the newest, least-guarded repo — a prototype, an intern's fork, an
archived service nobody watches — can assume the same role as the deploy
pipeline. Your blast radius is now the weakest repo in the organisation, and it
grows every time someone clicks "New repository".

**3. It fails open, and silently.** A too-narrow `sub` breaks loudly: the job
cannot assume the role and CI goes red. A too-broad one works perfectly, forever,
and nothing in any log distinguishes a legitimate deploy from an attacker's
workflow — both present a valid token for the same role. There is no failure to
detect, which is why this is worth getting right at write time rather than
discovering in an incident review.

The same reasoning applies to `aud`. Pinning it to `sts.amazonaws.com` stops a
token minted for another audience being replayed here.

A useful sharpening: the `sub` claim is an *authorisation* decision wearing
authentication's clothing. The OIDC token proves *which workflow* is asking —
GitHub signs it and cannot be spoofed. The trust policy decides *which of those
workflows is allowed*. Widening `sub` doesn't weaken the cryptography at all;
it just tells AWS to accept a much larger set of provably-genuine callers. The
signature stays perfect while the guarantee becomes worthless.
