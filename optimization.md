# Query Optimization

Four optimization attempts on the heaviest queries in this project, measured with
`EXPLAIN (ANALYZE, BUFFERS)` on PostgreSQL 17.

Two of the four didn't work. I've kept both failures here. "I added an index and
the planner ignored it" turned out to teach me more than the two that succeeded,
and cutting them would misrepresent how this actually went.

## How I measured

Each query ran five times and all five runs are printed below. The headline
number is the median, not the best.

That choice came out of a mistake. An earlier version of this document used
best-of-N and ended up reporting a "before" figure that was faster than a run
quoted elsewhere in the same file. That's impossible, and it happened because I
was comparing numbers taken in different cache states. Printing all five runs
makes that kind of error visible instead of hiding it behind one number.

The first run in each set is consistently the slowest (354 ms against a 117 ms
median in optimization 1). That's cold cache, not the query.

Plan excerpts below quote structure only: node types, row counts, cost estimates.
Timings come from the run tables and nowhere else. Mixing the two is what caused
the contradiction above, since a plan captured right after `CREATE INDEX` runs
cold and isn't comparable to a warm median.

Every table was `ANALYZE`d before measuring. Without current statistics the
planner works from stale estimates and its choices don't tell you anything.

> All of this was measured on a laptop with the 1.5M-row dataset sitting
> comfortably in RAM. Absolute numbers on a disk-bound server would look
> different. What transfers is the shape of each result: what the planner picked
> and why.

## Summary

| # | Change | Before (median) | After (median) | Result |
|---|---|---:|---:|---|
| 1 | Materialise geolocation centroids | 117.3 ms | 38.8 ms | 3.0x faster |
| 2 | Index `customers.customer_unique_id` | 6.22 ms | 0.568 ms | 11.0x faster |
| 3 | Partial index on `orders(purchase_ts) WHERE delivered` | 61.6 ms | 60.2 ms | Ignored, dropped |
| 4 | Covering index `order_items(seller_id) INCLUDE (price)` | 36.6 ms | 41.1 ms | Ignored, dropped |

---

## 1. Materialising the geolocation centroids: 3.0x faster

### The problem

`geolocation` is the worst-shaped table in the dataset. It has 1,000,163 rows
covering only 19,015 zip prefixes, so about 53 rows each, and 261,831 of them are
exact duplicates. There's no primary key because the raw data has no unique
column.

Any query needing coordinates had to aggregate all million rows first.

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 354.7 | 173.8 | 108.9 | 117.3 | 110.1 | **117.3 ms** |
| After | 49.1 | 33.0 | 38.8 | 51.4 | 33.2 | **38.8 ms** |

### Plan before

```
->  Finalize HashAggregate  (cost=17527.05..17651.23 rows=12418 width=22)
      (actual rows=19015 loops=1)
      ->  Partial HashAggregate  (cost=13857.18..13981.36 rows=12418 width=6)
            (actual rows=14649 loops=3)
            ->  Parallel Seq Scan on geolocation
                  (cost=0.00..12815.35 rows=416735 width=6)
                  (actual rows=333388 loops=3)
```

Three parallel workers scanning a million rows to produce 19,015, every single
time the query ran.

### The change

```sql
CREATE MATERIALIZED VIEW geolocation_centroid AS
SELECT geolocation_zip_code_prefix AS zip,
       AVG(geolocation_lat) AS lat,
       AVG(geolocation_lng) AS lng,
       COUNT(*)             AS source_rows
FROM geolocation GROUP BY 1;

CREATE UNIQUE INDEX idx_geo_centroid_zip ON geolocation_centroid (zip);
```

### Plan after

```
->  Seq Scan on geolocation_centroid cg  (cost=0.00..330.15 rows=19015 width=6)
      (actual rows=19015 loops=2)
```

The parallel aggregation is gone. Cost falls from 17,527 to 330, a 53x drop,
which is almost exactly the row-multiplication factor of the raw table.

| | Rows | Size |
|---|---:|---:|
| `geolocation` | 1,000,163 | 68 MB |
| `geolocation_centroid` | 19,015 | 1.5 MB |

### Why it got faster

The old query recomputed the same 19,015 centroids from a million rows on every
execution. The answer never changes, so computing it once and storing it removes
the work entirely.

Size helps too. 68 MB won't stay in cache alongside everything else. 1.5 MB will.

The estimate also became exact: 19,015 predicted against 19,015 actual, where
before it guessed 12,418. Better estimates lead to better join choices further up
the plan.

The cost is staleness. A materialized view is a stored snapshot, so if
`geolocation` changed this would keep serving old coordinates until someone ran
`REFRESH MATERIALIZED VIEW`. For a static dataset that's free. On live data it
needs a refresh schedule, which is real operational work.

It's also a correctness fix, not just a speed one. Joining `geolocation` directly
multiplies revenue by about 154x (13.2M becomes 2.03bn, see `05_joins.sql` Q3).
The view is unique by construction, so the fast path and the correct path are now
the same path. `queries/05_joins.sql` Q3 joins the view rather than the raw table.

---

## 2. Indexing `customer_unique_id`: 11.0x faster

### The problem

`customer_unique_id` is the column every retention and lifetime-value query
depends on, and it had no index. Only `customer_id`, the primary key, was
indexed, and that's the wrong column for these questions.

The test query pulls one customer's full order history. That customer has 17 rows
in `customers`, one per order placed, which is the whole `customer_id` vs
`customer_unique_id` problem in miniature.

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 20.24 | 6.22 | 6.15 | 6.27 | 6.19 | **6.22 ms** |
| After | 0.568 | 0.560 | 0.740 | 0.629 | 0.568 | **0.568 ms** |

### Plan before

```
->  Seq Scan on customers c  (cost=0.00..2747.01 rows=20 width=66)
      (actual rows=17 loops=1)
```

All 99,441 rows read to find 17.

### Plan after

```
->  Index Scan using idx_customers_unique_id on customers c
      (cost=0.42..8.44 rows=1 width=66) (actual rows=17 loops=1)
```

Cost drops from 2,747 to 8.44, which is the planner's own reason for switching.

### Why it got faster

A sequential scan reads every row and tests it. A B-tree index goes straight to
the matching entries.

This only works because the query is selective. One customer out of 96,096 is
roughly 0.001% of the table. That's exactly where an index pays off, and it sets
up the next two results.

---

## 3. Partial index on `orders`: no effect, dropped

### The attempt

Every analytical query filters `order_status = 'delivered'`, and the trend queries
add a date range on top. Textbook case for a partial index:

```sql
CREATE INDEX idx_orders_delivered_purchased
    ON orders (order_purchase_timestamp)
    WHERE order_status = 'delivered';
```

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 97.0 | 50.5 | 61.6 | 66.6 | 59.7 | **61.6 ms** |
| After | 61.7 | 51.9 | 60.7 | 50.7 | 60.2 | **60.2 ms** |

A 1.4 ms gap against a 10 ms spread between runs, so it's noise. The planner
ignored the index completely:

```
->  Seq Scan on orders o  (cost=0.00..3580.22 rows=51603) (actual rows=52783)
```

`pg_stat_user_indexes` confirmed it: `idx_scan = 0`.

### Why the planner was right

The query reads 52,783 of 99,441 orders. That's 53% of the table.

An index scan isn't free. For every matching entry it has to jump from the index
back to the heap to get the row, and those jumps are effectively random access.
Doing that for half a table costs more than reading the table straight through in
physical order.

Rule of thumb: once a query touches more than about 5-10% of a table, a
sequential scan usually wins. At 53% it isn't close.

There's a second problem specific to this data. `order_status = 'delivered'`
matches 96,478 of 99,441 rows, or 97% of the table. A partial index that excludes
almost nothing is basically a full index, so it saves neither space nor
maintenance.

Dropped. It took up 2.1 MB and had to be updated on every write to `orders`, in
exchange for never being used once.

---

## 4. Covering index on `order_items`: no effect, dropped

### The attempt

Seller revenue aggregation feeds both the ranking and Pareto queries. A covering
index should allow an index-only scan:

```sql
CREATE INDEX idx_order_items_seller_covering
    ON order_items (seller_id) INCLUDE (price);
```

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 36.6 | 47.1 | 36.4 | 34.9 | 45.4 | **36.6 ms** |
| After | 41.1 | 46.8 | 34.6 | 36.3 | 48.9 | **41.1 ms** |

The "after" median is slower, though both sit inside a 14 ms spread, so the fair
reading is no measurable difference. `idx_scan = 0` again:

```
->  Parallel Seq Scan on order_items oi  (actual rows=56325 loops=2)
```

### Why it didn't work

The query aggregates almost every row. It sums revenue across all delivered
orders, roughly 110,000 of 112,650 line items, or 98% of the table. An index
can't help you skip rows when you need essentially all of them.

The index had a second flaw. The query joins `order_items` to `orders` on
`order_id`, but the index only covers `seller_id` and `price`. An index-only scan
needs every referenced column present, so PostgreSQL would have had to visit the
heap anyway, losing the one advantage on offer.

Dropped. It cost 6.5 MB and slowed every write to the largest table in the
database, for nothing.

---

## What the four results add up to

Indexes speed up selective access. They do nothing for full-table aggregation.
Optimizations 3 and 4 failed for the same underlying reason: both queries need
most of the table, and no index makes reading everything faster than reading
everything sequentially.

The two that worked did so for different reasons:

- #2 was selective, one row in 96,096, which is what a B-tree is built for.
- #1 wasn't an index at all. It was a structural change that removed repeated
  work. The biggest gain came from asking "why is this being recomputed every
  time?" rather than "which column should I index?"

Unused indexes aren't free either. They take up space and have to be maintained on
every write. I dropped both failures rather than leaving them in, and
`pg_stat_user_indexes.idx_scan` is how I decided that on evidence instead of a
hunch.

Trust the planner, then check it. In both failures the planner was right and my
assumption was wrong. `EXPLAIN ANALYZE` is what tells you which of those two
you're looking at.

---

## What breaks at 100x the data

At 155M rows some of this changes and some of it doesn't.

**Gets worse:**

- Full-table aggregations become the whole problem. Queries 3 and 4 are fine at
  112k rows because scanning them is cheap. At 11M line items, scanning for every
  dashboard refresh isn't viable. The fix isn't an index, it's pre-aggregation:
  a rollup table of daily revenue per seller per category, updated incrementally,
  so the dashboard reads thousands of rows instead of millions. Same lesson as
  optimization 1, applied more broadly.
- `order_items` and `orders` would want partitioning by month. Most analytical
  queries filter on a date range, and with monthly partitions the planner can skip
  irrelevant partitions before reading anything. That's what actually turns "scan
  everything" into "scan a slice." It's also where optimization 3 would finally
  pay off, since a date filter selecting 2% of a partitioned table behaves nothing
  like one selecting 53% of a small table.
- Window functions become memory-bound. Every `SUM() OVER (PARTITION BY ... ORDER
  BY ...)` sorts its partition, and at 100x those sorts spill to disk. `EXPLAIN`
  starts showing `Sort Method: external merge  Disk: ...` instead of `quicksort
  Memory:`. Raising `work_mem` helps up to a point, after which you aggregate
  before windowing rather than after.
- The recursive CTE in `04_ctes.sql` degrades badly. It re-joins the full leaf set
  on each of its five passes, so 100x means five passes over 1.9M leaf rows. As
  that file already says, `GROUPING SETS` would do it in one.
- `COUNT(DISTINCT ...)` gets expensive, since exact distinct counts require
  sorting or hashing every value. Where an approximation is fine, `postgres_hll`
  trades a small error for a big speedup.
- The haversine distance in `05_joins.sql` Q3 is computed per row. At 11M line
  items it's better precomputed per `(seller_zip, customer_zip)` pair, since far
  fewer pairs actually occur than exist.

**Doesn't change:**

- The geolocation centroid gets better, not worse. It collapses 1M rows to 19k no
  matter how much order data there is, because zip codes don't multiply when
  orders do.
- The `customer_unique_id` index stays useful. B-tree depth grows
  logarithmically, so selective lookups scale fine.

The short version: the two optimizations that worked would still work at 100x,
and the two that failed would still fail for the same reason. What changes is that
the failures stop being harmless. Here a full scan costs milliseconds. At 100x the
same query shape is what takes the database down.
