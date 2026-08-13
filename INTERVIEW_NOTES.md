# Interview Notes

A prep sheet for defending this project. For each query: what it does, why this
approach over the alternatives, and what breaks at 100× the data.

Written to be read the night before, not skimmed in the room.

---

## Start here: the three things worth leading with

If you only remember three things, make them these. They are what separate this
from a project that just runs.

**1. You found a wrong number in your own work and fixed it.**
The late-delivery rate was reported as 8.11%. It is 6.77%.
`order_estimated_delivery_date` is stored at **midnight for all 99,441 orders** —
it records a promised *day*, not an instant. Comparing full timestamps counted an
order promised for the 10th and delivered at 09:00 *on* the 10th as late. That
was 1,292 orders, **16.5% of the apparent late total**.

The fix came from asking *why is this column always midnight?* — not from a test
failing. That is the answer to "tell me about a time you caught a mistake."

**2. Two of four optimizations failed, and you can explain why the planner was
right.** Most portfolio projects show only wins. `optimization.md` shows an index
the planner refused to use because the query reads 53% of the table, and a
covering index that could never work because it omitted a column the join needed.

**3. `customer_id` is not the customer.** Olist issues a new one per order.
Grouping by it reports every customer as a one-time buyer with exactly 1.000
orders. The real person is `customer_unique_id`. This single fact invalidates
most naive analysis of this dataset, and Q1 of `04_ctes.sql` measures both side
by side rather than asserting it.

---

## The dataset in one paragraph

Olist, a Brazilian marketplace: 99,441 orders from 96,096 people across 3,095
sellers, September 2016 to October 2018. 1,550,922 rows over 9 tables. Delivered
orders total **13,221,498 BRL**, which is 97.4% of all revenue.

---

## Conventions, and why each was chosen

Expect to be asked why. Each of these is a decision you should be able to defend
in one sentence.

| Convention | Reasoning |
|---|---|
| Revenue = `SUM(order_items.price)` | Freight is a pass-through logistics cost, not merchandise revenue. Stated explicitly wherever it differs. |
| Only `order_status = 'delivered'` | 97.4% of revenue. Cancelled orders are revenue that never existed. |
| `LEFT JOIN` + `COALESCE` for categories | 2 of 73 categories have no English translation. An inner join silently deletes their revenue. |
| Money is `NUMERIC(10,2)` | Binary floats cannot represent decimal currency exactly, and error compounds across 112,650 line items. |
| Zip codes are `CHAR(5)` | 24,000 begin with `0`. An integer column destroys them. |
| Lateness compared by **date**, not timestamp | Estimated dates are stored at midnight — the promise is a day. |
| Analysis window 2017-01 to 2018-08 | See below. |

### Why the analysis window excludes both ends

Two independent reasons, both found by profiling and both invisible in a summary
statistic:

- **November 2016 does not exist.** Zero orders — not zero delivered, zero
  orders. So `LAG()` over the raw series reported December's previous month as
  *October*. Silent, no error.
- **The tail is right-censored.** September 2018 has 16 orders and October has 4,
  but **none were delivered** when the dataset was extracted. Charting them shows
  revenue falling off a cliff — that is the export date, not the business.

The head is equally unusable: September 2016 is one order (135 BRL), December
2016 is one order (10.90 BRL).

---

## 01_ranking.sql

**What it does:** Top-N analysis — best products per category, top sellers per
state, leading category per state, and seller revenue concentration.

**Q1 — comparing `RANK` / `DENSE_RANK` / `ROW_NUMBER` on real ties.**
Telephony has two products tied at 68 units and two more at 53.

```
units   ROW_NUMBER   RANK   DENSE_RANK
 68         3          3        3
 68         4          3        3
 59         5          5        4     <- RANK skipped 4
 53         6          6        5
 53         7          6        5
 50         8          8        6     <- RANK skipped 7
```

- `ROW_NUMBER` — always distinct, breaks ties arbitrarily
- `RANK` — ties share a rank, then **skips** positions
- `DENSE_RANK` — ties share a rank, never skips

**Why it matters:** "top 5 by `ROW_NUMBER`" returns only one of two equally
selling products, and *which one* is not deterministic.

> **This actually bit the project.** The file was non-deterministic for three
> days — the tied products swapped between runs. `ROW_NUMBER` now takes an
> explicit tiebreak (`product_id`) while `RANK` and `DENSE_RANK` deliberately do
> not, because adding one there would make every row unique and destroy the ties
> being demonstrated. That asymmetry is the real lesson: `RANK` is deterministic
> in its values regardless of peer order; `ROW_NUMBER` is not.

**Why window functions instead of `GROUP BY`:** `GROUP BY` collapses a group to
one row. It can tell you the top revenue per category but not *which product*
earned it, and cannot return the top five. The pre-window alternative is a
correlated subquery per row ("how many products beat me?"), which rescans the
table once per row.

**Why the filter is in an outer query:** `WHERE` is evaluated **before** window
functions. Referring to `revenue_rank` in a `WHERE` on the same level is a syntax
error. The CTE is what makes the window result filterable.

**Where `ROW_NUMBER` is correct:** Q4 asks for exactly one category per state.
An arbitrary tiebreak is acceptable and a tie must not return two rows. `RANK`
would break the "one row per state" contract.

**At 100×:** Ranking degrades gracefully — window functions sort per partition,
and partitions stay small (73 categories, 27 states) even as rows grow. The
sorts eventually spill to disk (`Sort Method: external merge` in `EXPLAIN`).
`NTILE` over all sellers is the weak point: it must sort every seller globally.

---

## 02_trend_analysis.sql

**What it does:** Month-over-month growth, moving averages, year-over-year
comparison, and category momentum.

**The central technique — a date spine.** `LAG()` returns the previous **row**,
not the previous **month**. A month with no orders produces no row, so `LAG`
reaches across the gap silently. `generate_series` produces every month, a
`LEFT JOIN` attaches revenue, and now `LAG` genuinely means "last month".

**The distinction worth understanding — two defects, one fix.** The spine fixes
*alignment*. It does **not** fix the +1,025,573% growth rate for January 2017,
because the reference month is now genuinely December — which holds one 11 BRL
order. That is a tiny-denominator problem needing a *different* fix (the analysis
window). Conflating them is how a wrong number survives review, because it now
comes from correct-looking code.

**`ROWS` vs `RANGE`.** Not interchangeable:

- `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` — counts **rows**
- `RANGE BETWEEN INTERVAL '2 months' PRECEDING AND CURRENT ROW` — counts **values**

Across the missing month they disagree: at 2016-12, `ROWS` averages Sep+Oct+Dec
(13,490); `RANGE` averages Oct+Dec only (20,168), because September is three
calendar months back. **`ROWS` is only safe once you have guaranteed the gaps
away.**

**Two bugs found here, both worth describing:**

1. **Every YoY value came back NULL.** The filter `WHERE month >= '2018-01-01'`
   sat in the same `SELECT` as `LAG(revenue, 12)`. `WHERE` runs first, cutting
   the input to 8 rows, so `LAG` had nothing to reach back to. No error — just an
   empty column that looks like missing data.
2. **A trend baseline that contained the thing it measured.** `pct_vs_ma_3mo`
   made each month ⅓ of its own denominator. February 2017 grew +109.5% but
   scored +35.4%, and January scored exactly `0.0` — a value divided by itself,
   reading as "perfectly on trend" with no trend data at all. Replaced with a
   trailing frame (`ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING`). **November 2017's
   Black Friday signal went from +32.1% to +63.7%** — it had been halved.

**Also:** moving averages now return `NULL` until the frame is full, guarded by
`COUNT(*) OVER` the same frame. Previously `ma_6mo` on row 1 averaged one month
and printed it as a six-month average.

**At 100×:** `generate_series` is unaffected — months don't multiply. The
aggregation feeding it does. The answer is a pre-aggregated monthly rollup table
maintained incrementally, so the trend query reads hundreds of rows instead of
millions.

---

## 03_partition_calculations.sql

**What it does:** Running totals, cumulative sums per customer and region, and a
Pareto curve.

**The one thing to understand:** `SUM(x) OVER (ORDER BY d)` is **not** a running
total. It is only a running total when `d` has no duplicates. Omitting the frame
selects the default:

```
RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
```

`RANGE` operates on **values**, so "current row" means every row sharing that
value — all its peers.

**Demonstrated on real data.** Customer `12f5d6e1` placed six orders on
2017-01-05:

```
order_brl | default_frame_range | explicit_rows
     9.90 |               58.40 |          9.90
     6.90 |               58.40 |         16.80
     9.90 |               58.40 |         26.70
     9.90 |               58.40 |         36.60
    10.90 |               58.40 |         47.50
    10.90 |               58.40 |         58.40
```

The default returns **58.40 on every row** — the running total does not run.
Both are standards-correct; only one answers the question.

**The detail that makes this dangerous:** they agree on the **final row**. A
spot-check of the last value passes. Only the intermediate rows lie.

**The real fix is a unique `ORDER BY`, not just an explicit frame.** Even
`ROWS UNBOUNDED PRECEDING` leaves peer order unspecified among ties — `EXPLAIN`
showed the column only looked monotonic because the planner reused a sort
demanded by a *different* column. An explicit frame is the safety net; a
deterministic ordering is the actual defence.

**`LAST_VALUE` usually lies.** With the default frame it returns the current
row's own value, because the frame *ends* at the current row. `FIRST_VALUE`
happens to work, which is exactly why the bug is easy to miss — half the query is
right. `MIN()`/`MAX()` as plain window aggregates need no frame reasoning and
cannot be got wrong.

**Partition by `customer_unique_id`, never `customer_id`.** Partitioning by
`customer_id` gives every partition exactly one row, so every "running total"
equals that single order.

**At 100×:** This is the most exposed file. Every `SUM() OVER (PARTITION BY ...
ORDER BY ...)` sorts its partition. At 100× the sorts spill to disk. Raising
`work_mem` helps; past a point you aggregate *before* windowing rather than
after. The Pareto query is worst — it sorts every seller globally.

---

## 04_ctes.sql

**What it does:** Customer lifetime value (non-recursive), value segmentation,
and a recursive walk of the zip-prefix hierarchy.

**What a CTE actually is.** A named subquery. It buys **readability, not speed**.
Since PostgreSQL 12 a plain CTE is normally **inlined**, so it optimises like a
subquery — it is not a temp table and not automatically materialised. Before 12
they were always materialised, an "optimisation fence" people exploited
deliberately. Code written against that assumption can change behaviour on
upgrade.

> **Expect the follow-up: "when would you use `MATERIALIZED`?"**
> When an expensive CTE is referenced **more than once**. This project originally
> had a `MATERIALIZED` hint justified by a comment claiming the CTE was
> "referenced twice" — it was referenced once. With a single reference the hint
> can only hurt: it blocks inlining and predicate pushdown. It was removed.
> Adding optimizer hints on a plausible-sounding reason rather than a plan is how
> queries get slower.

**The LTV result, measured both ways:**

| Method | Customers | Avg LTV | Avg orders | Repeat buyers |
|---|---:|---:|---:|---:|
| by `customer_unique_id` (correct) | 93,358 | 141.62 | 1.033 | 3.00% |
| by `customer_id` (wrong) | 96,478 | 137.04 | 1.000 | **0.00%** |

**Be ready for: "LTV on a base where 97% bought once — is that even meaningful?"**
The honest answer is *barely*, and that is itself the finding. Only **5.5% of
revenue** comes from repeat customers. On this data, acquisition matters far more
than retention, and a retention programme would be optimising a 5.5% slice.
Saying so is stronger than defending a metric that does not apply.

**The recursive CTE — and why it may be the wrong tool.**
It walks a zip-prefix tree: `0 → 01 → 011 → 0110 → 01100`, depth 5, built one
digit at a time.

**Say this before they do:** the hierarchy has a **fixed** depth, and for fixed
depth `GROUPING SETS` would be simpler and faster in a single pass. Recursion
genuinely earns its place at *variable* depth — org charts, bills of materials,
threaded comments — which cannot be written as a fixed list of grouping sets at
all. It is used here because the project must demonstrate the technique, and the
trade-off is documented rather than hidden.

**Two PostgreSQL constraints that shaped it:**

- The recursive term may not contain aggregates, `GROUP BY`, or `DISTINCT`. So
  recursion builds the **node list only**; revenue is aggregated afterwards.
- `UNION`, not `UNION ALL` — `UNION` deduplicates, collapsing the many leaf zips
  sharing a prefix into one node per level.
- Always bound the recursion (`WHERE depth < 5`). Unbounded recursion on a cyclic
  graph runs until it exhausts memory.

**Q4 is a correctness assertion as a query:** all five depths must total the same
revenue. They do — **13,221,498.11** at every level. Worth writing whenever a
join condition is cleverer than equality.

**At 100×:** The recursive CTE degrades badly — it re-joins the full leaf set on
each of five passes, so 100× means five passes over 1.9M leaf rows.
`GROUPING SETS` would do it in one.

---

## 05_joins.sql

**What it does:** Five tables joined to locate where late deliveries concentrate,
and what they cost.

### The headline result

| Delivery outcome | Orders | Avg score | 1–2 star |
|---|---:|---:|---:|
| 10+ days early | 61,849 | 4.32 | 8.9% |
| 1–9 days early | 26,795 | 4.23 | 9.9% |
| On the promised day | 1,292 | 4.04 | 12.3% |
| 1–3 days late | 1,870 | 3.29 | 32.2% |
| 4–10 days late | 2,572 | 1.97 | 71.4% |
| More than 10 days late | 2,092 | 1.71 | 78.8% |

**The insight is the asymmetry.** Arriving 10+ days early scores 4.32 versus 4.23
on time — essentially nothing. Arriving late is catastrophic. There is no upside
to beating the promise, only downside to missing it. Commercially that argues for
*accurate* delivery estimates rather than conservative ones.

### The two join traps, measured

**Fan-out from joining two children of `orders`:**

```
                method                | row_count | item_revenue_brl | payment_total_brl
--------------------------------------+-----------+------------------+-------------------
 WRONG: both children joined directly |    115035 |      13813828.71 |       19776160.44
 CORRECT: each child pre-aggregated   |     96478 |      13221498.11 |       15422461.77
```

An order with 3 items and 2 payments yields 6 rows; each price counted twice,
each payment three times. Payments overstated by **28%** — plausible enough to
survive review.

**The geolocation trap — 154× inflation:**

```
 correct (no geo join)  |   13221498.11 |   110197 rows
 naive geolocation join | 2032852520.88 | 16842720 rows
```

`geolocation` holds ~53 rows per zip prefix. Nothing errors; it just returns a
number wrong by two orders of magnitude.

**Rule:** never join two child tables to the same parent without pre-aggregating,
and check the grain of every table before joining it.

### Grain bugs found in review — worth being able to describe

- **Averages at the wrong grain.** The CTE deduplicated on `(order, seller_id)`
  while counting `DISTINCT order_id`. An order split between two sellers in the
  same state was averaged twice but counted once — the *rates* were protected and
  the *averages* silently were not. Fixed by deduplicating at the grain the query
  groups on. **General rule: the CTE grain should match the `GROUP BY`, or every
  aggregate has to be individually defended.**
- **One order in several distance bands.** A multi-seller order has multiple
  distances, so the `orders` column summed to more than the 96,470 delivered
  orders. Fixed with one row per order using `MAX(distance)` — the order is not
  complete until its furthest item arrives. Now sums to exactly 96,470.
- **Silently dropped rows.** An inner join to geolocation removed orders with
  unmapped zips. Now `LEFT JOIN`, with the **476** affected orders reported in
  their own band. The same hidden self-selection the review file warns about.

**Also:** haversine distance, not Pythagorean — a degree of longitude is not a
fixed distance, and Brazil spans 33 degrees of latitude, so the error would be
large and systematically biased by region.

**At 100×:** The haversine calculation runs per row. At 11M line items it is
worth precomputing per `(seller_zip, customer_zip)` pair — far fewer distinct
pairs occur than exist. The five-way join wants `order_items` partitioned by
month so date filters prune before reading.

---

## optimization.md

Four attempts. **Two failed.** Being able to explain the failures is the point.

| # | Change | Before | After | Result |
|---|---|---:|---:|---|
| 1 | Materialise geolocation centroids | 117.3 ms | 38.8 ms | **3.0×** |
| 2 | Index `customer_unique_id` | 6.22 ms | 0.568 ms | **11.0×** |
| 3 | Partial index on `orders` | 61.6 ms | 60.2 ms | Ignored — dropped |
| 4 | Covering index on `order_items` | 36.6 ms | 41.1 ms | Ignored — dropped |

**Why #3 failed:** the query reads **53% of the table**. An index scan must jump
from index to heap per row — effectively random access. Past roughly **5–10%** of
a table, a sequential scan wins. Also, `order_status = 'delivered'` matches 97%
of rows, so a partial index on it excludes almost nothing.

**Why #4 failed:** the query aggregates **98%** of rows — no index helps you skip
rows you all need. And the index covered `seller_id` and `price` but not
`order_id`, which the join needs, so an index-only scan was impossible anyway.

**Why #1 was the biggest win and wasn't an index:** the same 19,015 centroids
were re-derived from a million rows on *every execution*. The largest gain came
from asking "why is this recomputed every time?" rather than "which column should
I index?" It is also a **correctness** fix — the view is unique by construction,
so the fast path and the correct path became the same path.

**Unused indexes are not free.** Both failures cost 8.6 MB and had to be
maintained on every write. `pg_stat_user_indexes.idx_scan = 0` is how that was
decided factually rather than by guessing.

> **On method — expect this if they read carefully.** An earlier draft reported
> best-of-N and produced a "before" figure *faster* than a run quoted elsewhere
> in the same document, and a 207 ms child node inside a 110 ms query. Both
> impossible, both caused by mixing measurement runs. The document now prints
> **all five runs**, uses the **median**, and quotes plan *structure* separately
> from timing. Owning this is stronger than hoping nobody checks.

---

## The "100× data" answer, condensed

If asked once, generally:

**What breaks:** full-table aggregations — they are cheap at 112k rows and fatal
at 11M. The answer is not an index; it is **pre-aggregation** (incrementally
maintained rollup tables) and **partitioning by month** so date filters prune
before reading. Window function sorts spill to disk. `COUNT(DISTINCT ...)`
becomes expensive — `postgres_hll` trades a small error for a large speedup.

**What doesn't:** the geolocation centroid gets *better* — it collapses 1M rows to
19k regardless of order volume, because zip codes don't multiply when orders do.
B-tree lookups scale logarithmically.

**The sharp version:** the two optimizations that worked would still work at
100×; the two that failed would still fail, for the same reason. What changes is
that the failures stop being harmless — here a full scan costs milliseconds; at
100× the same query shape takes the database down.

---

## Questions to have an answer ready for

**"Why PostgreSQL and not a warehouse?"**
The dataset is 1.5M rows — it fits comfortably in Postgres, and the techniques
(window functions, CTEs, `EXPLAIN`) transfer directly to Snowflake/BigQuery. At
100× the answer changes: columnar storage would beat row storage for these
scan-heavy aggregations.

**"How do you know your numbers are right?"**
Three ways. The loader verifies every table against canonical row counts and
exits non-zero on mismatch. `04_ctes.sql` Q4 asserts all five hierarchy depths
total identically. Every query file is verified byte-reproducible across runs —
which is how the non-determinism in `01_ranking.sql` was caught.

**"What would you do differently?"**
Profile the data *before* writing the schema, which happened here, but also
profile *semantics* before writing queries. The midnight-timestamp issue would
have been caught on day one by checking the distribution of
`order_estimated_delivery_date::time` rather than assuming a timestamp column
carries a meaningful time.

**"What is the weakest part of this project?"**
The recursive CTE. It demonstrates the technique on a fixed-depth hierarchy where
`GROUPING SETS` would be better. Said before they say it, that is a strength.

**"What surprised you?"**
That being early is worth almost nothing (4.32 vs 4.23) while being late is
ruinous (1.71). It inverts the intuition that faster delivery is always better —
what matters is *accuracy* of the promise, not speed.
