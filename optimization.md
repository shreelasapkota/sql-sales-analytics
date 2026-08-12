# Query Optimization

Three optimization attempts on the heaviest queries in this project, measured
with `EXPLAIN (ANALYZE, BUFFERS)` on PostgreSQL 17.

**Two of the three failed.** Both failures are kept here, because "I added an
index and the planner ignored it" is a more useful thing to understand than a
list of wins — and because deleting the failures would misrepresent how
optimization actually goes.

## Method

Every figure below is the **best of 5 runs** of `EXPLAIN (ANALYZE, BUFFERS)`.
Best-of rather than average, because the first run pays for a cold cache and
averaging it in measures disk warm-up rather than the query.

All tables were `ANALYZE`d before measuring. Without current statistics the
planner works from stale row estimates and its choices say nothing useful.

> These timings come from a laptop with the whole 1.5M-row dataset comfortably
> in RAM (`Buffers: shared hit=...`, almost no `read=`). Absolute numbers on a
> disk-bound server would differ substantially. The *shape* of each result — what
> the planner chose and why — is what transfers.

## Summary

| # | Change | Before | After | Result |
|---|---|---:|---:|---|
| 1 | Materialise geolocation centroids | 110.1 ms | 34.4 ms | **3.2× faster** |
| 2 | Index `customers.customer_unique_id` | 6.965 ms | 0.563 ms | **12.4× faster** |
| 3 | Partial index on `orders(purchase_ts) WHERE delivered` | 49.4 ms | 50.3 ms | **No effect — dropped** |
| 4 | Covering index `order_items(seller_id) INCLUDE (price)` | 35.5 ms | 34.8 ms | **No effect — dropped** |

---

## 1. Materialising the geolocation centroids — 3.2× faster

### The problem

`geolocation` is the worst-shaped table in the dataset: **1,000,163 rows covering
just 19,015 zip prefixes** — about 53 rows each, including 261,831 exact
duplicates. It has no primary key, because the raw data has no unique column.

Any query needing coordinates had to aggregate all million rows first.

### Before

```
->  Finalize HashAggregate  (cost=17527.05..17651.23 rows=12418 width=22)
      (actual time=207.253..208.251 rows=19015 loops=1)
      Buffers: shared hit=929 read=7719
```

Two things to read here. The aggregation alone takes **207 ms** to produce
19,015 rows — and it did that on every execution.

The `read=7719` matters too: 7,719 blocks pulled from disk rather than found in
cache. `geolocation` is too large to stay resident alongside everything else.

Note also the estimate: the planner guessed 12,418 groups and got 19,015. Not a
disaster, but a reminder that estimates on a table with no statistics-friendly
key are approximate.

### The change

```sql
CREATE MATERIALIZED VIEW geolocation_centroid AS
SELECT geolocation_zip_code_prefix AS zip,
       AVG(geolocation_lat) AS lat,
       AVG(geolocation_lng) AS lng
FROM geolocation GROUP BY 1;

CREATE UNIQUE INDEX idx_geo_centroid_zip ON geolocation_centroid (zip);
```

### After

```
->  Seq Scan on geolocation_centroid cg  (cost=0.00..318.15 rows=19015 width=6)
      (actual time=0.042..6.980 rows=19015 loops=2)
```

The 207 ms aggregation is gone entirely, replaced by a 7 ms scan of a small
table. The estimate is now exact — 19,015 predicted, 19,015 actual — because the
row count is a stored fact rather than a guess.

| | Rows | Size |
|---|---:|---:|
| `geolocation` | 1,000,163 | 68 MB |
| `geolocation_centroid` | 19,015 | 1.5 MB |

### Why it got faster, in plain language

The old query re-derived the same 19,015 centroids from a million rows *every
single time it ran*. The work never changed, so doing it once and storing the
answer removes it entirely.

The secondary win is size. 68 MB does not stay resident in cache alongside
everything else; 1.5 MB does. That is why the `read=` blocks disappear — after
the first run the whole thing lives in memory.

The `UNIQUE` index does more than enforce correctness. It tells the planner that
at most one row can match a given zip, which sharpens its row estimates for
every join against it.

**The trade-off is staleness.** A materialised view is a stored snapshot. If
`geolocation` changed, this would silently serve old coordinates until
`REFRESH MATERIALIZED VIEW` ran. For a static dataset that cost is zero; on live
data it would need a refresh schedule, and that is a real operational burden, not
a free win.

**This is also a correctness fix, not only a speed one.** Joining `geolocation`
directly multiplies revenue by ~154× (13.2M → 2.03bn, see `05_joins.sql` Q3).
The centroid view makes the join 1:1, so the fast path and the correct path are
now the same path.

---

## 2. Indexing `customer_unique_id` — 12.4× faster

### The problem

`customer_unique_id` identifies the actual person and drives every retention and
lifetime-value query, but had no index. Only `customer_id` — the primary key —
was indexed, and that is the *wrong* column for these questions.

The test query pulls one customer's full order history. That customer holds 17
rows in `customers` — one per order placed — which is the whole point of the
`customer_id` vs `customer_unique_id` distinction.

### Before

```
->  Seq Scan on customers c  (cost=0.00..2747.01 rows=17 width=66)
      (actual time=0.933..5.997 rows=17 loops=1)
Execution Time: 6.642 ms
```

All 99,441 rows read to find 17.

### After

```
->  Index Scan using idx_customers_unique_id on customers c
      (cost=0.42..8.44 rows=1 width=66)
      (actual time=0.034..0.063 rows=17 loops=1)
Execution Time: 0.720 ms
```

The plan excerpts above are from a single representative run; the summary table
quotes best-of-5 for both, which is where the 12.4× figure comes from.

Note the cost estimate drops from 2747.01 to 8.44 — the planner's own arithmetic
for why it switched.

### Why it got faster

A sequential scan reads every row and tests each one. A B-tree index descends
directly to the matching entries — a handful of page reads instead of 99,441 row
comparisons.

**This only works because the query is selective.** One customer out of 96,096
is roughly 0.001% of the table. That is exactly the shape where an index wins,
and it sets up the next two results.

---

## 3. Partial index on `orders` — no effect, dropped

### The attempt

Every analytical query filters `order_status = 'delivered'`, and the trend
queries add a date range. That looks like a textbook case for a partial index:

```sql
CREATE INDEX idx_orders_delivered_purchased
    ON orders (order_purchase_timestamp)
    WHERE order_status = 'delivered';
```

### The result

| | Time |
|---|---:|
| Before | 49.437 ms |
| After | 50.323 ms |

The planner **ignored it completely** and kept the sequential scan:

```
Seq Scan on orders o  (cost=0.00..3580.22 rows=51278) (actual rows=52783)
```

`pg_stat_user_indexes` confirmed it: `idx_scan = 0`.

### Why the planner was right

The query reads **52,783 of 99,441 orders — 53% of the table.**

An index scan is not free. For each matching entry it must jump from the index
back to the heap to fetch the row, and those jumps are effectively random
access. Doing that for half a table costs far more than reading the table
straight through in physical order.

The rule of thumb: **once a query touches more than roughly 5–10% of a table, a
sequential scan usually wins.** At 53% it is not close.

There is a second reason specific to this data. `order_status = 'delivered'`
matches 96,478 of 99,441 rows — **97% of the table**. A partial index that
excludes almost nothing is close to a full index, so it saves neither space nor
work.

The index was dropped. It occupied 2.1 MB and had to be updated on every write
to `orders`, in exchange for never being used.

---

## 4. Covering index on `order_items` — no effect, dropped

### The attempt

Seller revenue aggregation is used by both the ranking and the Pareto queries. A
covering index should allow an **index-only scan**, where PostgreSQL answers
entirely from the index without touching the table:

```sql
CREATE INDEX idx_order_items_seller_covering
    ON order_items (seller_id) INCLUDE (price);
```

### The result

| | Time |
|---|---:|
| Before | 35.481 ms |
| After | 34.773 ms |

Within run-to-run noise, and again `idx_scan = 0`:

```
Parallel Seq Scan on order_items oi  (actual rows=56325 loops=2)
```

### Why it did not work

**The query aggregates nearly every row.** It sums revenue across all delivered
orders — about 110,000 of 112,650 line items, 98% of the table. An index cannot
help you skip rows when you need essentially all of them.

There is a second flaw in the index itself. The query joins `order_items` to
`orders` on `order_id`, but the index covers only `seller_id` and `price`. An
index-only scan requires *every* referenced column to be present, so PostgreSQL
would have had to visit the heap anyway — losing the only advantage on offer.

The index was dropped. It cost 6.5 MB and slowed every write to the largest
table in the database, for nothing.

---

## What these four results add up to

**Indexes accelerate selective access. They do nothing for full-table
aggregation.** Optimizations 3 and 4 failed for the same underlying reason:
both queries need most of the table, and no index makes reading everything
faster than reading everything sequentially.

The two that worked did so for genuinely different reasons:
- **#2 was selective** — one row in 96,096, exactly what a B-tree is for.
- **#1 was not an index at all.** It was a structural change that removed
  repeated work. The largest win here came from asking "why is this computed
  every time?" rather than "which column should I index?"

**Unused indexes are not free.** They consume space and must be maintained on
every insert, update and delete. Both failures were dropped rather than left in
place, and `pg_stat_user_indexes.idx_scan` is how that decision was made
factually rather than by guessing.

**Trust the planner, then verify it.** In both failures the planner was correct
and the index was the mistake. `EXPLAIN ANALYZE` is what distinguishes "the
planner is being stupid" from "my assumption was wrong" — and here it was
consistently the latter.

---

## What breaks at 100× this data

At 155M rows the conclusions above shift, and it is worth being precise about
which ones.

**What gets worse:**

- **The full-table aggregations become the whole problem.** Queries 3 and 4 are
  fine at 112k rows because scanning them is cheap. At 11M line items, scanning
  the table for every dashboard refresh is not viable. The fix is not an index —
  it is **pre-aggregation**: a rollup table of daily revenue per seller per
  category, maintained incrementally, so the dashboard reads thousands of rows
  instead of millions.

- **`order_items` would want partitioning by month.** Most analytical queries
  filter on a date range. With monthly partitions the planner prunes irrelevant
  partitions before reading anything, which is the one thing that genuinely
  turns "scan everything" into "scan a slice". This is also where optimization 3
  would finally start paying off — a date-range filter that selects 2% of a
  partitioned table behaves very differently from one selecting 53% of a small one.

- **The window functions become memory-bound.** Every `SUM() OVER (PARTITION BY
  ... ORDER BY ...)` sorts its partition. At 100× the sorts spill from memory to
  disk, and `EXPLAIN` starts reporting `Sort Method: external merge  Disk: ...`
  instead of `quicksort  Memory:`. Raising `work_mem` for the session helps; past
  a point the answer is to aggregate before windowing rather than after.

- **The recursive CTE in `04_ctes.sql` degrades badly.** It re-joins the full
  leaf set on every one of its five passes. At 100× that is five passes over
  1.9M leaf rows. As noted in that file, `GROUPING SETS` is the better tool for a
  fixed-depth hierarchy and would do it in a single pass.

- **The `COUNT(DISTINCT ...)` calls get expensive.** Exact distinct counts
  require sorting or hashing every value. Where an approximation is acceptable,
  `postgres_hll` or similar trades a small error for a very large speedup.

**What does not change:**

- The **geolocation centroid** win gets *better*, not worse. It collapses 1M rows
  to 19k regardless of how much order data exists, because zip codes do not
  multiply when orders do.
- The **`customer_unique_id` index** stays valuable. Selective lookups are
  exactly what scales well with a B-tree — the index depth grows only
  logarithmically.

**The honest summary:** the two optimizations that worked here would still work
at 100×. The two that failed would still fail, for the same reason. What changes
is that the failures stop being harmless — at this size a full scan costs
milliseconds, and at 100× the same query shape is what takes the database down.
