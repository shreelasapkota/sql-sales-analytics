# Query Optimization

Four optimization attempts on the heaviest queries in this project, measured with
`EXPLAIN (ANALYZE, BUFFERS)` on PostgreSQL 17.

**Two of the four failed.** Both failures are kept here, because "I added an
index and the planner ignored it" is more useful to understand than a list of
wins — and because deleting them would misrepresent how optimization actually
goes.

## Method

Each query was run **five times** and every run is printed below. The headline
figure is the **median**, not the best.

That choice matters, and an earlier draft of this document got it wrong. Using
best-of-N produced a "before" figure faster than a run observed elsewhere in the
same document — an impossible result that came from comparing numbers taken in
different cache states. Printing all five runs makes that class of error visible
instead of hiding it behind a single number.

The first run of each set is consistently the slowest (354 ms vs a 117 ms
median in optimization 1). That is cold-cache warm-up, not the query.

**Plan excerpts below quote structure — node types, row counts, cost estimates —
not timings.** Timings come only from the five-run tables. Mixing the two is what
produced the contradiction in the earlier draft, because a plan captured right
after a `CREATE INDEX` runs against a cold cache and is not comparable to a
warm-state median.

All tables were `ANALYZE`d before measuring. Without current statistics the
planner works from stale estimates and its choices say nothing useful.

> These timings come from a laptop with the 1.5M-row dataset comfortably in RAM.
> Absolute numbers on a disk-bound server would differ substantially. The *shape*
> of each result — what the planner chose and why — is what transfers.

## Summary

| # | Change | Before (median) | After (median) | Result |
|---|---|---:|---:|---|
| 1 | Materialise geolocation centroids | 117.3 ms | 38.8 ms | **3.0× faster** |
| 2 | Index `customers.customer_unique_id` | 6.22 ms | 0.568 ms | **11.0× faster** |
| 3 | Partial index on `orders(purchase_ts) WHERE delivered` | 61.6 ms | 60.2 ms | **Ignored — dropped** |
| 4 | Covering index `order_items(seller_id) INCLUDE (price)` | 36.6 ms | 41.1 ms | **Ignored — dropped** |

---

## 1. Materialising the geolocation centroids — 3.0× faster

### The problem

`geolocation` is the worst-shaped table in the dataset: **1,000,163 rows covering
just 19,015 zip prefixes** — about 53 rows each, including 261,831 exact
duplicates. It has no primary key, because the raw data has no unique column.

Any query needing coordinates had to aggregate all million rows first.

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 354.7 | 173.8 | 108.9 | 117.3 | 110.1 | **117.3 ms** |
| After | 49.1 | 33.0 | 38.8 | 51.4 | 33.2 | **38.8 ms** |

### Plan, before

```
->  Finalize HashAggregate  (cost=17527.05..17651.23 rows=12418 width=22)
      (actual rows=19015 loops=1)
      ->  Partial HashAggregate  (cost=13857.18..13981.36 rows=12418 width=6)
            (actual rows=14649 loops=3)
            ->  Parallel Seq Scan on geolocation
                  (cost=0.00..12815.35 rows=416735 width=6)
                  (actual rows=333388 loops=3)
```

Three parallel workers scan a million rows and aggregate them down to 19,015 —
on every execution.

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

### Plan, after

```
->  Seq Scan on geolocation_centroid cg  (cost=0.00..330.15 rows=19015 width=6)
      (actual rows=19015 loops=2)
```

The parallel aggregation is gone. Cost drops from 17,527 to 330 — a 53× drop in
the planner's own arithmetic, which is almost exactly the row-multiplication
factor of the raw table.

| | Rows | Size |
|---|---:|---:|
| `geolocation` | 1,000,163 | 68 MB |
| `geolocation_centroid` | 19,015 | 1.5 MB |

### Why it got faster, in plain language

The old query re-derived the same 19,015 centroids from a million rows *every
single time it ran*. The work never changed, so doing it once and storing the
answer removes it entirely.

The secondary win is size. 68 MB does not stay resident in cache alongside
everything else; 1.5 MB does.

Note the estimate also became exact — 19,015 predicted, 19,015 actual, versus
12,418 predicted before. Better estimates lead to better join decisions
downstream.

**The trade-off is staleness.** A materialised view is a stored snapshot. If
`geolocation` changed, this would serve old coordinates until `REFRESH
MATERIALIZED VIEW` ran. For a static dataset that cost is zero; on live data it
needs a refresh schedule, which is a real operational burden.

**This is also a correctness fix, not only a speed one.** Joining `geolocation`
directly multiplies revenue by ~154× (13.2M → 2.03bn, see `05_joins.sql` Q3).
The centroid view makes the join 1:1 by construction, so the fast path and the
correct path are now the same path — and `queries/05_joins.sql` Q3 joins the
view rather than the raw table.

---

## 2. Indexing `customer_unique_id` — 11.0× faster

### The problem

`customer_unique_id` identifies the actual person and drives every retention and
lifetime-value query, but had no index. Only `customer_id` — the primary key —
was indexed, and that is the *wrong* column for these questions.

The test query pulls one customer's full order history. That customer holds 17
rows in `customers`, one per order placed, which is the whole point of the
`customer_id` vs `customer_unique_id` distinction.

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 20.24 | 6.22 | 6.15 | 6.27 | 6.19 | **6.22 ms** |
| After | 0.568 | 0.560 | 0.740 | 0.629 | 0.568 | **0.568 ms** |

### Plan, before

```
->  Seq Scan on customers c  (cost=0.00..2747.01 rows=20 width=66)
      (actual rows=17 loops=1)
```

All 99,441 rows read to find 17.

### Plan, after

```
->  Index Scan using idx_customers_unique_id on customers c
      (cost=0.42..8.44 rows=1 width=66) (actual rows=17 loops=1)
```

Cost falls from 2,747 to 8.44 — the planner's own reasoning for switching.

### Why it got faster

A sequential scan reads every row and tests each. A B-tree index descends
directly to the matching entries.

**This only works because the query is selective.** One customer out of 96,096
is roughly 0.001% of the table. That is exactly the shape where an index wins,
and it sets up the next two results.

---

## 3. Partial index on `orders` — no effect, dropped

### The attempt

Every analytical query filters `order_status = 'delivered'`, and the trend
queries add a date range. That looks like a textbook partial index:

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

A 1.4 ms difference against a 10 ms spread between runs — indistinguishable from
noise. The planner ignored the index entirely:

```
->  Seq Scan on orders o  (cost=0.00..3580.22 rows=51603) (actual rows=52783)
```

`pg_stat_user_indexes` confirmed it: **`idx_scan = 0`**.

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
maintenance work.

Dropped. It occupied 2.1 MB and had to be updated on every write to `orders`, in
exchange for never being used.

---

## 4. Covering index on `order_items` — no effect, dropped

### The attempt

Seller revenue aggregation is used by both the ranking and Pareto queries. A
covering index should allow an **index-only scan**:

```sql
CREATE INDEX idx_order_items_seller_covering
    ON order_items (seller_id) INCLUDE (price);
```

### Measurements

| Run | 1 | 2 | 3 | 4 | 5 | Median |
|---|---:|---:|---:|---:|---:|---:|
| Before | 36.6 | 47.1 | 36.4 | 34.9 | 45.4 | **36.6 ms** |
| After | 41.1 | 46.8 | 34.6 | 36.3 | 48.9 | **41.1 ms** |

The "after" median is *slower*, though both sit inside a ~14 ms run-to-run
spread, so the honest reading is no measurable difference. Again **`idx_scan = 0`**:

```
->  Parallel Seq Scan on order_items oi  (actual rows=56325 loops=2)
```

### Why it did not work

**The query aggregates nearly every row.** It sums revenue across all delivered
orders — about 110,000 of 112,650 line items, 98% of the table. An index cannot
help you skip rows when you need essentially all of them.

There is a second flaw in the index itself. The query joins `order_items` to
`orders` on `order_id`, but the index covers only `seller_id` and `price`. An
index-only scan requires *every* referenced column to be present, so PostgreSQL
would have had to visit the heap anyway — losing the only advantage on offer.

Dropped. It cost 6.5 MB and slowed every write to the largest table in the
database, for nothing.

---

## What these four results add up to

**Indexes accelerate selective access. They do nothing for full-table
aggregation.** Optimizations 3 and 4 failed for the same underlying reason: both
queries need most of the table, and no index makes reading everything faster
than reading everything sequentially.

The two that worked did so for genuinely different reasons:

- **#2 was selective** — one row in 96,096, exactly what a B-tree is for.
- **#1 was not an index at all.** It was a structural change that removed
  repeated work. The largest win came from asking "why is this recomputed every
  time?" rather than "which column should I index?"

**Unused indexes are not free.** They consume space and must be maintained on
every write. Both failures were dropped rather than left in place, and
`pg_stat_user_indexes.idx_scan` is how that decision was made factually rather
than by guessing.

**Trust the planner, then verify it.** In both failures the planner was correct
and the index was the mistake. `EXPLAIN ANALYZE` is what distinguishes "the
planner is being stupid" from "my assumption was wrong" — here it was
consistently the latter.

---

## What breaks at 100× this data

At 155M rows the conclusions above shift, and it is worth being precise about
which ones.

**What gets worse:**

- **The full-table aggregations become the whole problem.** Queries 3 and 4 are
  fine at 112k rows because scanning them is cheap. At 11M line items, scanning
  for every dashboard refresh is not viable. The fix is not an index — it is
  **pre-aggregation**: a rollup table of daily revenue per seller per category,
  maintained incrementally, so the dashboard reads thousands of rows instead of
  millions. That is optimization #1's lesson applied more broadly.

- **`order_items` and `orders` would want partitioning by month.** Most
  analytical queries filter on a date range. With monthly partitions the planner
  prunes irrelevant partitions before reading anything, which genuinely turns
  "scan everything" into "scan a slice". This is also where optimization 3 would
  finally pay off: a date filter selecting 2% of a partitioned table behaves
  very differently from one selecting 53% of a small one.

- **The window functions become memory-bound.** Every `SUM() OVER (PARTITION BY
  ... ORDER BY ...)` sorts its partition. At 100× the sorts spill to disk, and
  `EXPLAIN` starts reporting `Sort Method: external merge  Disk: ...` instead of
  `quicksort  Memory:`. Raising `work_mem` helps; past a point the answer is to
  aggregate before windowing rather than after.

- **The recursive CTE in `04_ctes.sql` degrades badly.** It re-joins the full
  leaf set on each of its five passes. At 100× that is five passes over 1.9M
  leaf rows. As that file already notes, `GROUPING SETS` is the better tool for
  a fixed-depth hierarchy and would do it in one pass.

- **`COUNT(DISTINCT ...)` gets expensive.** Exact distinct counts require sorting
  or hashing every value. Where approximation is acceptable, `postgres_hll`
  trades a small error for a large speedup.

- **The haversine distance calculation in `05_joins.sql` Q3** is computed per
  order-item row. At 100× this is worth precomputing per (seller_zip,
  customer_zip) pair — there are only ~19,015² possible pairs but far fewer
  actually occurring, so a cached lookup would beat recalculating trigonometry
  11M times.

**What does not change:**

- The **geolocation centroid** win gets *better*, not worse. It collapses 1M rows
  to 19k regardless of how much order data exists, because zip codes do not
  multiply when orders do.
- The **`customer_unique_id` index** stays valuable. B-tree depth grows only
  logarithmically, so selective lookups scale well.

**The honest summary:** the two optimizations that worked here would still work
at 100×. The two that failed would still fail, for the same reason. What changes
is that the failures stop being harmless — at this size a full scan costs
milliseconds; at 100× the same query shape is what takes the database down.
