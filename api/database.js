'use strict';

/**
 * database.js
 * -----------------------------------------------------------------------------
 * Connection factories for MySQL and MongoDB.
 */

const mysql = require('mysql2/promise');
const { MongoClient } = require('mongodb');

// ---------------------------------------------------------------------------
// Environment configuration (with defaults for local runs)
// ---------------------------------------------------------------------------
const MYSQL_CONFIG = {
  host: process.env.MYSQL_HOST || 'mysql-db',
  port: Number(process.env.MYSQL_PORT || 3306),
  user: process.env.MYSQL_USER || 'root',
  password: process.env.MYSQL_PASSWORD || 'labpassword',
  database: process.env.MYSQL_DATABASE || 'capacity_lab',

  // OPS-2202 fix: pool sized via Little's Law (L = λ × W).
  // Target ~2,500 req/s on /api/patients/recent, whose query service time W
  // is ~1 ms → required L ≥ 2.5. We pick 20 for ~10× headroom and to absorb
  // slower endpoints (e.g. /api/patients/search which is a few ms per query).
  // MySQL's max_connections is 151 and there is 1 API instance, so 20 is
  // well within safe bounds (headroom for future replicas / other services).
  // queueLimit remains 0 (unbounded queue) so brief bursts don't 503 the
  // caller — bound the queue in front of this via a reverse-proxy / LB.
  waitForConnections: true,
  connectionLimit: 20,
  queueLimit: 0,
  connectTimeout: 10_000,
  maxIdle: 10,
  idleTimeout: 60_000,
  enableKeepAlive: true,
};

const MONGO_URI = process.env.MONGO_URI || 'mongodb://mongo-db:27017';
const MONGO_DB_NAME = process.env.MONGO_DB || 'capacity_lab';

// ---------------------------------------------------------------------------
// MySQL pool (singleton)
// ---------------------------------------------------------------------------
let pool;

function applySecret(secret) {
  MYSQL_CONFIG.host = secret.host;
  MYSQL_CONFIG.port = Number(secret.port);
  MYSQL_CONFIG.user = secret.username;
  MYSQL_CONFIG.password = secret.password;
  MYSQL_CONFIG.database = secret.dbname;
  // Aiven requires TLS. VERIFY_CA needs AIVEN_CA_PATH; REQUIRED is enough for C3.
  MYSQL_CONFIG.ssl = { rejectUnauthorized: false };
  pool = undefined;
}

/**
 * Pool occupancy, for /readyz (C4). mysql2 keeps these on the inner pool and
 * has used both arrays and Denque across versions, so read defensively —
 * a readiness probe must never throw.
 */
function poolStats() {
  const size = (c) => {
    if (!c) return 0;
    if (typeof c.length === 'number') return c.length;
    if (typeof c.size === 'function') return c.size();
    return 0;
  };
  const inner = pool && pool.pool ? pool.pool : null;
  if (!inner) return { limit: MYSQL_CONFIG.connectionLimit, all: 0, free: 0, queued: 0 };
  return {
    limit: MYSQL_CONFIG.connectionLimit,
    all: size(inner._allConnections),
    free: size(inner._freeConnections),
    queued: size(inner._connectionQueue),
  };
}

function getPool() {
  if (!pool) {
    pool = mysql.createPool(MYSQL_CONFIG);
  }
  return pool;
}

// ---------------------------------------------------------------------------
// MongoDB client (singleton, lazily connected)
// ---------------------------------------------------------------------------
let mongoClient;
let mongoDb;

async function getMongo() {
  if (!mongoDb) {
    mongoClient = new MongoClient(MONGO_URI, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await mongoClient.connect();
    mongoDb = mongoClient.db(MONGO_DB_NAME);
  }
  return mongoDb;
}

// ---------------------------------------------------------------------------
// Graceful shutdown helpers
// ---------------------------------------------------------------------------
async function closeAll() {
  if (pool) {
    try { await pool.end(); } catch (_) { /* ignore */ }
    pool = undefined;
  }
  if (mongoClient) {
    try { await mongoClient.close(); } catch (_) { /* ignore */ }
    mongoClient = undefined;
    mongoDb = undefined;
  }
}

module.exports = {
  MYSQL_CONFIG,
  MONGO_URI,
  MONGO_DB_NAME,
  applySecret,
  poolStats,
  getPool,
  getMongo,
  closeAll,
};
