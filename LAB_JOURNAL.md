# 🧾 On-Call Lab Journal — Regional Health

**Engineer:** Akeza Saloi **Date:** 11th August 2026

This is your investigation notebook. You are on call for the Regional Health
platform and working the [incident queue](./incidents/README.md). For each
incident you will:

1. **Hypothesis** — from the ticket symptoms alone, predict the cause *before*
   you run anything.
2. **Observation** — record real evidence: k6 output, Grafana/Prometheus
   metrics, `EXPLAIN ANALYZE` plans, lock views, `docker stats`, container logs.
3. **Root cause & mechanism** — explain *why* it happens. Name the database/OS
   mechanic yourself and show the capacity math.
4. **Fix & verify** — make the change, re-run the reproduction, and record the
   before/after.

> There is no answer key. A claim without evidence isn't a diagnosis. "It felt
> slow" is not an observation; `p(95)=1840ms, http_req_failed=32%` is.

---

## How to capture evidence

- **k6:** copy the summary block (`http_req_duration`, `http_req_failed`,
  `iterations`, `vus`).
- **MySQL:** `docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab`
  then run `EXPLAIN ANALYZE ...`, `SHOW CREATE TABLE ...`,
  `SHOW ENGINE INNODB STATUS\G`, or query `performance_schema` / `sys`.
- **Metrics:** Grafana panels or raw Prometheus at http://localhost:9090.
- **Memory / restarts:** `docker stats`, `docker compose logs -f capacity-api`.

Useful Prometheus queries:
```promql
# Throughput (req/s) by route
sum(rate(http_requests_total[1m])) by (route)

# p95 latency by route
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, route))

# Application heap in use
nodejs_heap_size_used_bytes

# DB errors by code
sum(rate(db_errors_total[1m])) by (code)
```

---

## Baseline — steady state (do this first)
*Run:* `k6 run load-tests/00-baseline.js` (healthy system, no incident)

Capture the control group you'll compare every incident against.

| Metric              | Value |
|---------------------|-------|
| Requests/sec (RPS)  | 49.62 req/s (1500 iterations in 30s, 50 VUs with 1s sleep) |
| p50 latency         | 5.02 ms |
| p95 latency         | 17.0 ms |
| p99 latency         | 37.48 ms (max = 44.89 ms) |
| Error rate          | 0.00% (0/1500) |
| Peak API heap used  | ~22.9 MB (`max_over_time(nodejs_heap_size_used_bytes[15m])` on `capacity-api`) |

Raw k6 summary: `evidence/00-baseline.txt`.
> Added `summaryTrendStats: [..., 'p(99)']` to every k6 script so p99 is captured for every incident run too.

> SLOs I'll hold the incidents to:
> - **p95 latency < 200 ms** (matches the built-in k6 threshold in `00-baseline.js`)
> - **Error rate < 1%**
> - **RPS floor ≥ 40 req/s** (~80% of measured healthy throughput)
> - **Peak heap < 128 MB** (container cap is 160 MB — 20% headroom to survive GC spikes)

---

## Investigation — OPS-2201
*Ticket:* [Patient name search unusably slow at shift change](./incidents/OPS-2201.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2201.js`

### Hypothesis
> From the symptoms alone (fast when isolated, collapses under concurrent
> searches, other endpoints unaffected), I think the cause is
> a **full table scan on `patients.last_name`** (no usable index on the search
> column) because the query cost is O(N) per request. With one user, scanning
> ~100,000 rows once is tolerable; with 200 concurrent nurses each scanning the
> same table, CPU/IO is saturated and latency explodes. `/api/patients/recent`
> stays fast because it uses the primary key on `id` (`ORDER BY id DESC LIMIT 50`).
>
> **Kill-test:** `EXPLAIN ANALYZE SELECT * FROM patients WHERE last_name = 'Smith';`
> — hypothesis lives if `type=ALL` and rows examined ≈ 100,000; dies if the plan
> already uses an index and rows examined stays small.

### Observation (evidence)

**Schema before the fix** (`evidence/OPS-2201-explain-before.txt`):

```
CREATE TABLE patients (
  id INT AUTO_INCREMENT PRIMARY KEY,
  first_name VARCHAR(64), last_name VARCHAR(64),
  email VARCHAR(128), diagnosis VARCHAR(255), notes TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

SHOW INDEX FROM patients;
+---------+-----------+-------------+
| Key_name| Column    | Cardinality |
+---------+-----------+-------------+
| PRIMARY | id        | 98191       |    <-- only index; nothing on last_name
+---------+-----------+-------------+

EXPLAIN SELECT * FROM patients WHERE last_name = 'Smith';
type=ALL, possible_keys=NULL, key=NULL, rows=98191, Extra=Using where

EXPLAIN ANALYZE ...
-> Filter: last_name='Smith' (cost=10276 rows=9819) (actual time=0.02..21.6 rows=10000 loops=1)
   -> Table scan on patients   (cost=10276 rows=98191) (actual time=0.009..17.9 rows=100000 loops=1)
```

Hypothesis **CONFIRMED** at the SQL level — `type=ALL`, 100,000 rows scanned per request. Bonus finding: the seeder used only **9 distinct last names**, so a `Smith` lookup matches **10,000** rows and returns a ~3.6 MB payload every time.

**k6 reproduce (`evidence/reproduce-OPS-2201-before.txt`)** — 200 VUs × 30s at `GET /api/patients/search?lastName=Smith`:

| Metric (under load, no fix) | Value | vs. baseline |
|---|---|---|
| p50 latency | 5.83 s | 5.02 ms → **1,161× worse** |
| p95 latency | **7.60 s** | 17 ms → **447× worse** (SLO ✗) |
| p99 latency | 10.41 s | 37.5 ms → **278× worse** |
| RPS | 34.19 req/s | 49.62 → -31% |
| Error rate | 0.00% (0/1224) | same — Node queue absorbed everything |
| Rows examined / req | ~100,000 (full scan) | baseline endpoint uses PK → ~50 |
| Data received | 4.5 GB / 30s (~3.6 MB per response) | baseline ~18 kB/req |

MySQL state during load (`evidence/OPS-2201-mysql-under-load.txt`): only `Threads_running = 2` — foreshadowing that the app pool is the concurrency ceiling, not the DB itself.

### Root cause & mechanism

**Primary mechanism (DB layer):** InnoDB has to full-scan the `patients` clustered B-tree for every request because there is no secondary index on `last_name`. Cost per query is O(N) = O(100,000). Under 200 concurrent nurses, the buffer pool is warm but each scan still burns CPU parsing and comparing every row — and 200 scanners compete for the same pages.

**Capacity math (query cost, 100,000 rows, 9 distinct last names):**
- Full scan: N = 100,000 row comparisons + 100,000 row reads.
- Ideal (secondary B-tree index on `last_name`): ⌈log₂(100,000)⌉ ≈ 17 node comparisons to find the leaf, then 10,000 matched rows returned (still fat because the data is skewed — 10% of the table is "Smith"). Non-matching rows are **not touched** at all.
- Row-comparison ratio: 100,000 / 17 ≈ **5,882× cheaper** to *locate*. Actual analyze time dropped from 21.6ms → 10.8ms (~2× — the wall-clock win is smaller than the algorithmic win because returning 10k fat rows still dominates once you've found them).

**Secondary mechanism (surfaced by the evidence, not the ticket):** the app-side connection pool is capped at `connectionLimit: 2` (`api/database.js`), so end-to-end concurrency is 2 no matter how many nurses arrive. By Little's Law with the "after" numbers (`W ≈ 0.055s`, `L = 2`): `λ_max ≈ L/W ≈ 36 req/s` — matching the observed ~34 RPS. This is the *dominant* end-to-end bottleneck for this endpoint at 200 VUs; the missing index is the second-order cost. This is the same finite resource we'll take apart in OPS-2202.

### Fix & verify

**Change 1 (committed):** add a secondary B-tree index on `patients.last_name`, tracked as a SQL migration so the fix is reviewable.

- File: `data-seed/01-fixes.sql`
- Effect: `ALTER TABLE patients ADD INDEX idx_patients_last_name (last_name);`
- Applied with: `docker compose exec -T mysql-db mysql -uroot -plabpassword capacity_lab < data-seed/01-fixes.sql`

**Query-plan proof (`evidence/OPS-2201-explain-after.txt`):**

```
SHOW INDEX FROM patients;
| PRIMARY                | id        | 98191 |
| idx_patients_last_name | last_name |     9 |   <-- cardinality = 9 distinct last names

EXPLAIN SELECT * FROM patients WHERE last_name = 'Smith';
type=ref, key=idx_patients_last_name, rows=10000, Extra=NULL

EXPLAIN ANALYZE ...
-> Index lookup on patients using idx_patients_last_name (last_name='Smith')
   (cost=2371 rows=10000) (actual time=0.014..10.8 rows=10000 loops=1)
```

The full table scan is **gone** — plan is now `type=ref`, `key=idx_patients_last_name`, rows examined 100,000 → 10,000.

**k6 re-run (`evidence/reproduce-OPS-2201-after.txt`)** — same 200 VUs × 30s:

| Metric | Before fix | After fix | Change |
|---|---|---|---|
| p50 | 5.83 s | 5.73 s | -1.7% |
| p95 | **7.60 s** | **7.58 s** | -0.3% (SLO still ✗) |
| p99 | 10.41 s | 10.34 s | -0.7% |
| RPS | 34.19 | 34.59 | +1.2% |
| Data received / req | ~3.6 MB | ~3.6 MB | unchanged |
| Rows examined / req | ~100,000 | ~10,000 | **10× reduction** |

**⚠️ The "obvious" fix moved DB-side metrics dramatically but end-to-end p95 barely budged.** Why: with `connectionLimit: 2` the app pool serializes every request queue behind two connections, and each response serializes 10,000 rows (~3.6 MB) through JSON.stringify + the socket. The index fix eliminated the O(N) scan, but the remaining ceiling is set by `L = λ × W → λ ≤ 2/W`. Halving `W` from ~110ms to ~55ms doubled the theoretical ceiling, but 200 concurrent VUs still saturate a 2-slot pool.

**Trade-offs introduced:**
- Small write-amplification on `INSERT/UPDATE patients` (must maintain the extra B-tree).
- Modest storage bump (~a few MB) for the index.
- With `last_name` cardinality of only 9, the index is helpful but not selective — the optimizer might still ignore it for a query that returns >~20% of the table. Fine here (10%), but a real production system needs more distinct names or a composite index like `(last_name, first_name)` to be sharper.

**Follow-up planned:** re-run this reproduce script **after** OPS-2202's pool fix to prove the index is the right change for this endpoint. Expected result: p95 falls into the 100–300 ms range once the pool queue is unblocked.

**Follow-up result — the expectation was wrong** (`evidence/reproduce-OPS-2201-after-pool-fix.txt`): raising the app pool to 20 (OPS-2202 fix) made this endpoint **worse**, not better. p95: 7.58 s → **35.73 s**; RPS: 34.6 → 23.7. Why:

With pool=2, MySQL was *accidentally* rate-limiting the search to 2 fat 3.6 MB responses at a time, so Node's event loop only had to serialize 2 in parallel. With pool=20, MySQL happily returns 20 × 3.6 MB = ~72 MB of rows to Node concurrently, and Node's single-threaded event loop chokes trying to JSON.stringify and write them all — actual measured RPS drops.

There is a **third bottleneck** on this endpoint that neither the ticket nor the OPS-2202 fix touches: **the response payload is unbounded** (10,000 rows of ~360 bytes each = ~3.6 MB) because there is no `LIMIT` on the search query and the seeder gave `last_name` a cardinality of only 9. Proper fix (out of scope of the reported ticket, logged here for the synthesis section):

- Add a `LIMIT` (say 100) + `OFFSET`/keyset pagination to `/api/patients/search`.
- Or return only the fields the UI actually needs (`id, first_name, last_name`) instead of `SELECT *` including the `notes` TEXT column.
- Or stream the response with `res.write` per row (same technique OPS-2204 will need).

**Verdict:** OPS-2201's ticketed hypothesis (missing index → full scan) is confirmed at the SQL level. The ticket's *symptom* (p95 out of SLO) has two more causes stacked on top: (a) app pool queue [OPS-2202] and (b) unbounded response size — and the "correct" pool fix for (a) makes (b) worse. This endpoint needs all three fixes to hit its SLO. This finding is exactly the kind of "obvious fix isn't the fix" case the assignment rewards.

---

## Investigation — OPS-2202
*Ticket:* [Whole app freezes during surges, DB looks idle](./incidents/OPS-2202.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2202.js`

### Hypothesis
> Given the query is trivial and the DB is idle yet requests pile up, I think
> the bottleneck is **the application-tier MySQL connection pool** (queued
> requests waiting for a free connection in the Node/mysql2 pool) because a
> request cannot run its SQL until the app has a free DB handle to send it on.
> That's the only finite resource between the request arriving and the query
> executing, and it lives in the *app* — which is why MySQL looks bored while
> the app times out. I already spotted the smoking gun during OPS-2201:
> `api/database.js` sets `connectionLimit: 2`. With a 2,000-VU surge, 1,998
> requests queue for two slots.
>
> **Kill-test:** during the surge, compare app-side queue behaviour (throughput
> plateau + latency ≈ N × service-time / L) to MySQL's `Threads_running` and
> `Threads_connected` from `SHOW GLOBAL STATUS`. Hypothesis lives if MySQL sees
> ≤ 2 threads while k6 sees thousands of concurrent requests. Hypothesis dies
> if MySQL is actually busy (`Threads_running` climbs high, slow queries, or
> `max_connections` refusals) → then the queue is *inside* the DB, not the pool.

### Observation (evidence)

**k6 reproduce** — ramp 0→2,000 VUs in 5s, hold 25s, all hitting `GET /api/patients/recent` (the trivial `LIMIT 50` query).
Raw: `evidence/reproduce-OPS-2202-before.txt`.

**App-side signal**: `api/database.js` sets `connectionLimit: 2` and `queueLimit: 0` (unbounded queue) — the app can only ever have 2 SQL statements in flight at a time; everything else waits in an in-process queue with no timeout.

**MySQL state under 2,000-VU surge, pre-fix** (`evidence/OPS-2202-mysql-under-load.txt`):

```
Threads_running               = 2      -- exactly the pool ceiling
Threads_connected             = 3      -- 2 app-pool + 1 mysql shell
Max_used_connections          = 3      -- MySQL never saw more, ever
Aborted_connects              = 0
Connection_errors_max_connections = 0
```

MySQL's `max_connections = 151`, so the DB has ~148 idle slots waiting for callers that never arrive. **The DB is bored while the API is drowning.**

**App logs** (`evidence/OPS-2202-app.log`): a single line ("capacity-api listening on :3000") — no errors, no timeouts. Requests aren't failing; they're waiting inside the Node process for a pool slot.

| Metric | Value (2,000-VU surge, pool=2) | vs. baseline |
|---|---|---|
| Successful RPS (plateau) | **3,376 req/s** | +68× (throughput up because 50-VU baseline had a `sleep(1)`; the ceiling itself is `L/W`) |
| p50 latency | 576.4 ms | 5.02 ms → **115× worse** |
| p95 latency | **650.6 ms** | 17 ms → **38× worse** (SLO ✗) |
| p99 latency | 688.5 ms | 37.5 ms → 18× worse |
| Error / timeout rate | 0.00% (0/102,913) | same — pool queue is unbounded, so nothing 5xxs, everything just waits |
| Avg service time per query W | ~1 ms (MySQL side; `LIMIT 50` on the PK B-tree) | same |
| MySQL `Threads_running` during surge | **2** | 2 (unchanged) |
| MySQL `Threads_connected` during surge | **3** (2 app + 1 shell) | 3 (unchanged) |

Hypothesis **CONFIRMED**: 2,000 VUs pushing at a MySQL that only ever sees 2 connections. The paradox from the ticket ("DB is bored, app is dying") is explained mechanically.

### Root cause & mechanism

**The finite resource:** the **app-tier MySQL connection pool** (mysql2 in-process pool inside `capacity-api`). It's the *only* thing between the HTTP handler and MySQL, and it's capped at 2. Every request needs a slot; there are only 2 slots; everyone else waits. Because the queue has `queueLimit: 0` (unbounded), we don't get "connection refused" — we get "slow forever". The DB is uninvolved in the wait, which is why its dashboards look flat.

**Little's Law fit to the observed data:**
- Measured: `L = 2` (pool size), `λ ≈ 3,376 req/s`, `W_end-to-end ≈ 0.577 s` (median).
- Sanity: `λ × W = 3376 × 0.577 ≈ 1948` — approximately equal to the number of VUs in the queue at any instant (VUs = 2,000). ✓ Little's Law fits, queue is at steady state.
- The actual DB service time is `W_query ≈ 1 ms` (`LIMIT 50` on the PK). Latency is 577× W_query — the missing 576 ms is spent waiting for a pool slot, not executing SQL.

**Sizing the pool for the target SLO:**
- Target throughput: λ = 2,500 req/s (5× baseline surge headroom).
- Query service time: W_query ≈ 1 ms.
- Required pool: `L = λ × W = 2500 × 0.001 = 2.5`.
- Chose **L = 20** for ~10× headroom and to absorb slower endpoints (e.g. `/api/patients/search` where W is a few ms per query even with the index).

**Why making it arbitrarily large stops helping:** at some point, the *next* finite resource in the chain becomes the bottleneck. In order:
1. MySQL's `max_connections = 151` — hard ceiling on how many app slots can concurrently be open. Push past this and MySQL responds with `Too many connections`.
2. MySQL's CPU/IO — once you have hundreds of concurrent queries actually *running*, `Threads_running` climbs and each query slows down (context switches, buffer-pool page contention).
3. Node's single-threaded event loop — one process can only JSON-serialize and write responses so fast. Each 20 concurrent responses in flight contend on this. (We measured this directly — see "Follow-up" below.)
4. Kernel/OS: TCP accept queue, ephemeral port exhaustion, cgroup memory.

So the pool number is a *fitted parameter*, not "the biggest number that fits". Best practice: set the pool so it's the resource that gives you headroom in front of the *next* real bottleneck (usually DB CPU).

### Fix & verify

**Change (committed):** raise the app pool size in `api/database.js` from `2` to `20`, with an explanation of the Little's Law calculation in the code comment.

Rebuilt with `docker compose up -d --build capacity-api`.

**MySQL state under the same 2,000-VU surge, post-fix** (`evidence/OPS-2202-mysql-under-load-after.txt`):

```
Threads_running    = 3    -- still low: individual queries are ~1 ms each
Threads_connected  = 21   -- 20 app-pool + 1 shell (up from 3)
Max_used_connections = 21 -- 7× more than before, still well below max_connections=151
```

**Mechanism proof:** MySQL now sees 20 concurrent connections instead of 2. The app pool is *not* the queue anymore.

**k6 re-run (`evidence/reproduce-OPS-2202-after.txt`)** — same 2,000-VU surge:

| Metric | Before (pool=2) | After (pool=20) | Change |
|---|---|---|---|
| Successful RPS | 3,376 | **3,450** | +2% |
| p50 latency | 576 ms | 548 ms | -5% |
| p95 latency | 650 ms | 641 ms | -1% |
| p99 latency | 689 ms | **3.16 s** | **worse** |
| max latency | 715 ms | 9.81 s | worse |
| Error rate | 0.00% | 0.00% | same |
| MySQL connections | 3 | **21** | **+7×** |

**⚠️ What actually happened at 2,000 VUs:** the SLO-facing numbers barely moved because the bottleneck *moved*, it didn't disappear. With pool=2, every request paid a ~540 ms tax queueing in front of the mysql2 pool. With pool=20, that queue is gone — but now 20 responses are competing on Node's single-threaded event loop for JSON serialization and socket writes. The bottleneck jumped from **app-side pool queue** → **Node event-loop CPU** at this level of concurrency. Same laptop, same 3,450 req/s ceiling, but the queue is now in a different layer.

**Cross-verification — re-running OPS-2201 with pool=20** (`evidence/reproduce-OPS-2201-after-pool-fix.txt`) turned out **worse**: p95 7.58 s → **35.73 s**, RPS 34.6 → 23.7. Why: OPS-2201 returns a ~3.6 MB payload per request. With pool=2, MySQL was *accidentally* rate-limiting the endpoint to 2 fat responses at a time; with pool=20, Node now has 20 × 3.6 MB = ~72 MB of JSON to serialize in parallel and its event loop chokes. This is a **third bottleneck** on OPS-2201 (unbounded response size) that pool=2 was masking. The proper fix for OPS-2201 is pagination/LIMIT on the search endpoint — logged as a follow-up in the OPS-2201 section.

**Upstream protection that would make a burst degrade gracefully** rather than silently piling up in the pool queue:
- **Bound the queue.** Set `queueLimit: <N>` in the mysql2 pool (or a bounded `p-queue`), so overflow returns 503/429 immediately instead of waiting arbitrarily long.
- **Client-side timeouts + circuit breakers** (e.g. a fetch with a 500 ms timeout and a per-caller failure budget) so slow calls stop occupying pool slots.
- **Reverse-proxy concurrency limit** in front of the API (nginx `limit_conn`, envoy `max_pending_requests`) — a proper load-shedder that returns 503 with `Retry-After` when the app is saturated. This turns "everything hangs" into "some fraction of requests fail fast and clients back off".
- **Autoscaling on `pool_queue_depth`** if this were prod — export the pool's waiter count as a Prometheus gauge and scale the API horizontally on it.

**Alert that would have caught this before a ticket:** a Prometheus gauge on the mysql2 pool waiter count (or the ratio `pool_active / pool_size`) with an alert on `>80%` for 1 minute. Also a paired alert on `Threads_running` being suspiciously low while API p95 climbs — that's the fingerprint of app-side queueing.

---

## Investigation — OPS-2203
*Ticket:* [Bed admissions fail with DB errors under load](./incidents/OPS-2203.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2203.js`

### Hypothesis
> Given one-at-a-time works but concurrent admits to the *same* hospital fail,
> I think the cause is _____________________________________________________
> and the failure will show up as ______ (a DB error? a timeout? a stall?) ___.

### Observation (evidence)
> While the reproduction runs, inspect concurrent writers to one row:
> ```sql
> SELECT * FROM performance_schema.data_locks\G
> SELECT * FROM sys.innodb_lock_waits\G
> SHOW ENGINE INNODB STATUS\G   -- TRANSACTIONS section
> ```
> Paste the most telling waiter/blocker rows and the failure signature you saw
> (a DB error + code, a timeout, or stalled/near-zero throughput):
> ```
>
> ```
| Metric                     | Value | vs. baseline |
|----------------------------|-------|--------------|
| p95 / p99 latency          |       |              |
| Max successful admits/sec  |       |              |
| DB error(s) + code         |       |              |
| Error rate                 |       |              |

### Root cause & mechanism
> Explain why concurrency cannot beat serialization on a single hot row. If the
> critical section is held for W seconds per admit, what is the theoretical max
> throughput for that one row, regardless of how many callers pile on?
> 1 / W = ______ admits/sec. Where does the time in the critical section go, and
> which of the transactional guarantees is enforcing the wait? ________________

### Fix & verify
> The change you made (consider: shrinking the critical section, moving slow
> work out of the transaction, atomic guarded updates, reducing contention on
> the hot row): _____________________________________________________________
> Re-measured throughput / error rate: ______________________________________

---

## Investigation — OPS-2204
*Ticket:* [Nightly export crashes the service repeatedly](./incidents/OPS-2204.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2204.js`

### Hypothesis
> Given memory spikes right before each restart and only the big export is
> affected, I think the cause is ___________________________________________
> because __________________________________________________________________.

### Observation (evidence)
> Watch `nodejs_heap_size_used_bytes`, GC pauses, and restarts:
> ```bash
> docker stats
> docker compose logs -f capacity-api
> ```
| Metric                          | Value |
|---------------------------------|-------|
| Approx. payload size per request|       |
| Peak heap before crash          |       |
| Time-to-first-crash             |       |
| Container restart count         |       |
| GC pause trend                  |       |

> Paste the crash / exit log lines:
> ```
>
> ```

### Root cause & mechanism
> Estimate per-row size, then the full payload: rows × bytes/row = ______ MB.
> With C concurrent callers, peak resident memory ≈ ______ MB — compare to the
> container's memory budget (160MB locally / 256MB in prod). Explain what happens
> to GC frequency, CPU, and
> throughput as live heap approaches the limit, and why the current approach
> uses O(N) memory while a better one could use far less. ____________________

### Fix & verify
> The change you made (consider: bounding how much of the result set is in
> memory at once, streaming to the response, sensible page sizes, compression):
> ____________________________________________________________________________
> Re-run evidence — new peak heap: ______  restarts: ______  error rate: ______

---

## Post-incident review (synthesis)

> Rank the four incidents by **blast radius** (threat to overall availability at
> scale), justified with your measured numbers:
> 1. ____________________________________________________________________
> 2. ____________________________________________________________________
> 3. ____________________________________________________________________
> 4. ____________________________________________________________________
>
> If you could ship only **one** fix before a launch, which and why?
> ____________________________________________________________________________
>
> For each incident, what alert or dashboard would have caught it in production
> *before* a user filed a ticket? ____________________________________________
