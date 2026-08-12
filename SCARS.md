# Scar log — Regional Health On-Call

## OPS-2201 — Patient search full-scanned under concurrency

- **S — Symptom:** Concurrent last-name search p95 = **7.60 s** (baseline p95 = 17 ms, **447×** worse); `/api/patients/recent` stayed healthy.
- **C — Cause:** Stacked: (1) no index on `last_name` → full scan; (2) app pool=2; (3) unbounded Smith payloads (~10k rows / ~3.6 MB). Raising the pool alone made p95 **35.73 s**.
- **A — Action:** Index on `last_name`; later bound search with default `LIMIT 100` + slim columns (no `notes`) in `api/server.js`.
- **R — Result:** With index + pool=20 + LIMIT: p95 **35.73 s → 72.26 ms** (~494×), RPS 23.7 → **3,136**, SLO `p(95)<300` ✓.
- **Scar / lesson:** Prove the access path with `EXPLAIN`, but re-measure end-to-end. Fixing one scarce resource can expose the next (pool → payload size).
- **Evidence:** `evidence/OPS-2201-explain-{before,after}.txt`, `evidence/reproduce-OPS-2201-{before,after,after-pool-fix,after-limit}.txt`, journal §OPS-2201.

## OPS-2202 — Whole API frozen behind a 2-slot connection pool

- **S — Symptom:** Under 2,000-VU surge, trivial `/api/patients/recent` p95 = **650 ms** while MySQL looked idle (`Threads_running=2`, `Threads_connected=3`).
- **C — Cause:** App-tier mysql2 pool `connectionLimit: 2` + unbounded queue — requests wait in Node, not in MySQL.
- **A — Action:** Raised `connectionLimit` to **20** via Little's Law (`L = λ × W`; target ~2500 rps × ~1 ms ≈ 2.5, with headroom) in `api/database.js`.
- **R — Result:** MySQL connections 3 → **21**; mechanism fixed. At 2,000 VUs, p95 barely moved (bottleneck shifted to Node event-loop). Raising the pool made OPS-2201 **worse** until payload size is addressed.
- **Scar / lesson:** “Idle DB + slow app” → look at the pool. Sizing the pool moves the bottleneck; bound queues / load-shed for graceful degradation.
- **Evidence:** `evidence/OPS-2202-mysql-under-load{,-after}.txt`, `evidence/reproduce-OPS-2202-{before,after}.txt`, journal §OPS-2202.

## OPS-2203 — Hot-row lock serialized bed admissions

- **S — Symptom:** Concurrent admits to hospital `1`: ~**2** successful admits/sec, **45.6%** errors, p95 = **55.8 s**.
- **C — Cause:** Exclusive row lock held across a **500 ms** `notifyBedRegistry()` inside the transaction → ceiling `1/W = 2` admits/sec; waiters hit `ER_LOCK_WAIT_TIMEOUT` (1205).
- **A — Action:** Atomic `UPDATE ... WHERE id=? AND available_beds>0`; notify **after** lock release (`api/server.js`).
- **R — Result:** Successful throughput ~2 → **1,575** admits/sec (~**787×**); error rate 45.6% → **0%**; p95 55.8 s → **363 ms**.
- **Scar / lesson:** Never do slow I/O inside a row-locked transaction. Alert on `Innodb_row_lock_waits` / admit 1205 rate.
- **Evidence:** `evidence/OPS-2203-locks.txt`, `evidence/reproduce-OPS-2203-{before,after}.txt`, journal §OPS-2203.

## OPS-2204 — Export OOM-killed the container

- **S — Symptom:** Full export → mem **160/160 MiB**, `OOMKilled=true`, RestartCount **0→10**, **100%** request failures; took the instance down.
- **C — Cause:** Unbounded `SELECT *` buffered in app memory (~38.5 MB JSON/export × concurrency) vs 160 MB cgroup (V8 `--max-old-space-size=256`).
- **A — Action:** Streamed rows as NDJSON with mysql2 `.stream()` + backpressure; later added `MAX_CONCURRENT_EXPORTS=2` with fast **503** when saturated (`api/server.js`).
- **R — Result:** RestartCount stayed **0**; container mem ~**52/160 MiB**; error rate **0%** on successful stream path; 405/405 checks passed; **15 GB** successfully streamed. Concurrent overflow now fails fast with 503 instead of stacking.
- **Scar / lesson:** “Return everything” endpoints must stream or paginate — and bound concurrent expensive ops. Alert on memory vs cgroup limit + RestartCount before users page you.
- **Evidence:** `evidence/OPS-2204-under-load.txt`, `evidence/reproduce-OPS-2204-{before,after}.txt`, `evidence/OPS-2204-grafana-heap.png`, journal §OPS-2204.
