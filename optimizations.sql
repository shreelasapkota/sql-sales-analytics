-- =============================================================================
-- optimizations.sql — Objects added after measuring, not before
-- =============================================================================
-- Target: PostgreSQL 17
-- Usage:  psql -d olist -f optimizations.sql   (run after constraints.sql)
--
-- Everything here was added because a measurement justified it. Two other
-- indexes were built, measured, found unused, and dropped — that story is in
-- optimization.md, and the DDL for them is deliberately NOT here.
--
-- Run optimization.md's before/after yourself by dropping these and re-timing.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. geolocation_centroid — one row per zip prefix
-- -----------------------------------------------------------------------------
-- geolocation holds 1,000,163 rows for 19,015 zip prefixes, roughly 53 rows
-- each, with 261,831 exact duplicates. Every query needing coordinates had to
-- aggregate the full million rows first, and any query joining it directly
-- multiplied its own result set by ~53.
--
-- Materialising the centroids once turns a 68 MB / 1M-row aggregation into a
-- 1.5 MB / 19k-row indexed lookup. Measured: 110.1 ms -> 34.4 ms (3.2x).
--
-- A materialised view rather than a plain view because a plain view would
-- re-run the aggregation on every reference. The trade-off is staleness: this
-- must be refreshed if geolocation ever changes. For a static analytics dataset
-- that is free; on live data it would need a refresh schedule.
-- -----------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS geolocation_centroid CASCADE;

CREATE MATERIALIZED VIEW geolocation_centroid AS
SELECT
    geolocation_zip_code_prefix AS zip,
    AVG(geolocation_lat)        AS lat,
    AVG(geolocation_lng)        AS lng,
    COUNT(*)                    AS source_rows
FROM geolocation
GROUP BY 1;

-- UNIQUE, which does more than enforce correctness: it tells the planner at most
-- one row can match a given zip, which improves its row estimates for joins and
-- is what makes REFRESH MATERIALIZED VIEW CONCURRENTLY possible later.
CREATE UNIQUE INDEX idx_geo_centroid_zip ON geolocation_centroid (zip);

COMMENT ON MATERIALIZED VIEW geolocation_centroid IS
    'One row per zip prefix. Join this, never geolocation directly — the raw table fans out ~53x.';


-- -----------------------------------------------------------------------------
-- 2. customers.customer_unique_id
-- -----------------------------------------------------------------------------
-- customer_unique_id is the real person identifier and is used by every
-- retention, lifetime-value and repeat-purchase query, but it had no index —
-- only customer_id (the primary key) did.
--
-- For a SELECTIVE lookup (one customer out of 96,096) this is the difference
-- between scanning 99,441 rows and touching a handful.
-- Measured: 6.965 ms -> 0.563 ms (12.4x) for a single customer's order history.
--
-- Note this index does NOT help the population-wide LTV aggregation in
-- 04_ctes.sql, which reads every customer anyway. Indexes accelerate selective
-- access, not full scans — see optimization.md.
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_customers_unique_id
    ON customers (customer_unique_id);


ANALYZE customers;
ANALYZE geolocation_centroid;
