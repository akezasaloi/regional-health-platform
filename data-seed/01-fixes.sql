-- =============================================================================
-- 01-fixes.sql — schema fixes applied while working the incident queue
-- -----------------------------------------------------------------------------
-- Apply after seed.sh has populated the tables:
--   docker compose exec -T mysql-db mysql -uroot -plabpassword capacity_lab \
--     < data-seed/01-fixes.sql
-- =============================================================================

-- OPS-2201 — Patient name search unusably slow at shift change
-- -----------------------------------------------------------------------------
-- Before: `patients` had only PRIMARY KEY (id). Every `WHERE last_name = ?`
-- did a full table scan of ~100,000 rows (EXPLAIN: type=ALL).
-- Under 200 concurrent nurses at shift change, this saturated CPU and each
-- request queued behind the previous scan → p95 blew from 17ms → 7.6s.
--
-- Fix: add a B-tree secondary index on last_name so the lookup is O(log N).
-- Idempotent guard so re-running the file after a fresh seed is safe.
-- -----------------------------------------------------------------------------
SET @idx_exists := (
  SELECT COUNT(*) FROM information_schema.statistics
   WHERE table_schema = 'capacity_lab'
     AND table_name   = 'patients'
     AND index_name   = 'idx_patients_last_name'
);
SET @sql := IF(@idx_exists = 0,
  'ALTER TABLE patients ADD INDEX idx_patients_last_name (last_name)',
  'SELECT "idx_patients_last_name already exists" AS note');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
