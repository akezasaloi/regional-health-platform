'use strict';

/**
 * server.js
 * -----------------------------------------------------------------------------
 * Express API for the Regional Health admissions & patient-lookup service.
 *
 * Endpoints:
 *   GET  /api/patients/recent        Recent patients widget
 *   GET  /api/patients/search        Patient lookup by last name
 *   POST /api/hospitals/:id/admit    Admit a patient (decrement bed count)
 *   GET  /api/patients/export        Full patient export for the analytics team
 *   GET  /api/audit/ping             Mongo audit-store health probe
 *   GET  /metrics                    Prometheus metrics
 */

const express = require('express');
const client = require('prom-client');
const { getPool, getMongo } = require('./database');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 3000);

// ---------------------------------------------------------------------------
// Prometheus metrics
// ---------------------------------------------------------------------------
const register = new client.Registry();
register.setDefaultLabels({ app: 'capacity-api' });

// Default process/GC/heap metrics.
client.collectDefaultMetrics({ register, gcDurationBuckets: [0.001, 0.01, 0.1, 1, 2, 5] });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const dbErrorsTotal = new client.Counter({
  name: 'db_errors_total',
  help: 'Total number of database errors by type',
  labelNames: ['route', 'code'],
  registers: [register],
});

// Per-request timing + counting middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.baseUrl + req.route.path : req.path;
    const labels = { method: req.method, route, status_code: res.statusCode };
    end(labels);
    httpRequestsTotal.inc(labels);
  });
  next();
});

// ---------------------------------------------------------------------------
// Health & metrics
// ---------------------------------------------------------------------------
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// ---------------------------------------------------------------------------
// Recent patients widget
// ---------------------------------------------------------------------------
app.get('/api/patients/recent', async (_req, res) => {
  try {
    const pool = getPool();
    const [rows] = await pool.query(
      'SELECT * FROM patients ORDER BY id DESC LIMIT 50'
    );
    res.json({ count: rows.length, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/recent', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Patient lookup by last name
// OPS-2201 follow-up: bound the result set. Index alone + a larger pool still
// left p95 terrible because Smith matched ~10k rows (~3.6 MB). Default LIMIT
// keeps memory/CPU O(page size); callers can page with ?limit=&offset=.
// ---------------------------------------------------------------------------
app.get('/api/patients/search', async (req, res) => {
  const lastName = req.query.lastName || '';
  const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 100, 1), 500);
  const offset = Math.max(parseInt(req.query.offset, 10) || 0, 0);
  try {
    const pool = getPool();
    const [rows] = await pool.query(
      'SELECT id, first_name, last_name, email, diagnosis, created_at FROM patients WHERE last_name = ? ORDER BY id LIMIT ? OFFSET ?',
      [lastName, limit, offset]
    );
    res.json({ count: rows.length, lastName, limit, offset, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/search', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Admit a patient to a hospital (decrement available beds).
// OPS-2203: do NOT hold the row lock across the external registry notify.
// Atomic guarded UPDATE keeps Isolation/Atomicity without a long transaction.
// ---------------------------------------------------------------------------
app.post('/api/hospitals/:id/admit', async (req, res) => {
  const hospitalId = Number(req.params.id);
  const pool = getPool();
  try {
    const [result] = await pool.query(
      'UPDATE hospitals SET available_beds = available_beds - 1 WHERE id = ? AND available_beds > 0',
      [hospitalId]
    );
    if (result.affectedRows === 0) {
      return res.status(409).json({ error: 'NO_BEDS_AVAILABLE', hospitalId });
    }
    // Notify AFTER the row lock is released (fire-and-forget; prod would use a queue).
    notifyBedRegistry(hospitalId).catch(() => { /* retry elsewhere */ });
    res.json({ status: 'admitted', hospitalId });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/hospitals/:id/admit', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// Stand-in for the external registry client used by the admit flow.
function notifyBedRegistry(_hospitalId) {
  return new Promise((r) => setTimeout(r, 500));
}

// ---------------------------------------------------------------------------
// Full patient export for the analytics/ETL team.
// OPS-2204: stream rows as NDJSON — O(1) memory instead of buffering ~100k rows.
// Also cap concurrent exports so many callers cannot stack heap/CPU (P2 review).
// ---------------------------------------------------------------------------
const MAX_CONCURRENT_EXPORTS = Number(process.env.MAX_CONCURRENT_EXPORTS || 2);
let activeExports = 0;

app.get('/api/patients/export', async (_req, res) => {
  if (activeExports >= MAX_CONCURRENT_EXPORTS) {
    res.set('Retry-After', '5');
    return res.status(503).json({
      error: 'EXPORT_CAPACITY_EXCEEDED',
      message: `Too many concurrent exports (max ${MAX_CONCURRENT_EXPORTS}). Retry shortly.`,
    });
  }

  const pool = getPool();
  let conn;
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    activeExports = Math.max(0, activeExports - 1);
    if (conn) {
      try { conn.release(); } catch (_) { /* ignore */ }
    }
  };

  activeExports += 1;
  try {
    conn = await pool.getConnection();
    res.setHeader('Content-Type', 'application/x-ndjson');
    // Use the underlying mysql2 connection stream so rows are not buffered in JS.
    const stream = conn.connection
      .query('SELECT * FROM patients')
      .stream({ highWaterMark: 50 });

    stream.on('data', (row) => {
      const ok = res.write(JSON.stringify(row) + '\n');
      if (!ok) {
        stream.pause();
        res.once('drain', () => stream.resume());
      }
    });
    stream.on('end', () => {
      res.end();
      release();
    });
    stream.on('error', (err) => {
      dbErrorsTotal.inc({ route: '/api/patients/export', code: err.code || 'UNKNOWN' });
      if (!res.headersSent) res.status(500);
      res.end();
      release();
    });
    res.on('close', () => {
      stream.destroy();
      release();
    });
  } catch (err) {
    release();
    dbErrorsTotal.inc({ route: '/api/patients/export', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Mongo audit-store health probe
// ---------------------------------------------------------------------------
app.get('/api/audit/ping', async (_req, res) => {
  try {
    const db = await getMongo();
    const result = await db.command({ ping: 1 });
    res.json({ mongo: result });
  } catch (err) {
    res.status(500).json({ error: 'MONGO_ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`capacity-api listening on :${PORT} (metrics at /metrics)`);
});
