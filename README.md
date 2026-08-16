# SQL Sales Analytics

Analytical SQL on the Olist Brazilian e-commerce dataset. Window functions, CTEs,
ranking, trend analysis, and query optimization in PostgreSQL 17.

The data covers 99,441 orders from 96,096 customers and 3,095 sellers between
September 2016 and October 2018. That's 1,550,922 rows across 9 tables.

Every query here has been run against the real data. The numbers below are
measured, not estimated.

---

## Key insights

### 1. Being late wrecks your reviews. Being early buys you nothing.

| Delivery outcome | Orders | Avg review | 1-2 star |
|---|---:|---:|---:|
| 10+ days early | 61,849 | 4.32 | 8.9% |
| 1-9 days early | 26,795 | 4.23 | 9.9% |
| On the promised day | 1,292 | 4.04 | 12.3% |
| 1-3 days late | 1,870 | 3.29 | 32.2% |
| 4-10 days late | 2,572 | 1.97 | 71.4% |
| More than 10 days late | 2,092 | 1.71 | 78.8% |

Ten days early scores 4.32. One day early scores 4.23. So ten extra days of
padding buys you 0.09 of a star.

Go four days late and you lose 2.26 stars, with one and two star reviews jumping
from 9% to 71%.

The practical read: pad your estimates and you gain almost nothing, but miss the
date you promised and it costs you badly. Accuracy beats optimism.

**6.77% of delivered orders arrived late** (6,534 of 96,470). That number took
some care to get right. `order_estimated_delivery_date` is stored at midnight for
all 99,441 rows, so it's really a promised *day*, not a timestamp. If you compare
the full timestamps, an order promised for the 10th and delivered at 9am on the
10th counts as late. That inflates the rate to 8.11% and adds 1,292 orders that
were never actually late. All queries here compare dates instead.

### 2. Twenty-eight sellers bring in a quarter of the revenue

Of 2,970 sellers with delivered orders, 28 of them (0.9%) account for 25% of
revenue. 127 sellers (4.3%) account for half. 533 (17.9%) account for 80%. The
bottom decile contributes 0.1%.

Losing a few of the top sellers would hurt a lot.

### 3. This business runs on acquisition, not retention

97% of customers ordered exactly once (90,557 of 93,358). Repeat customers
account for 5.5% of revenue.

A retention programme here would be working on a 5.5% slice of the business.

You only see this if you group by `customer_unique_id`. Group by `customer_id`,
which is what the schema pushes you toward, and every customer looks like a
one-time buyer, so the finding disappears entirely.

### 4. Growth is slowing, and it was never about basket size

Year-over-year growth dropped from +727% in January 2018 to +51% by August.
Average order value fell over the same stretch, from 149 BRL to 132. So the
growth came from more orders, not bigger ones.

November 2017 is still the best month at 987,765 BRL, running 63.7% above its own
prior three-month baseline. Black Friday.

---

## ERD

See [docs/erd.md](docs/erd.md). It's generated from the live database catalogue,
so it shows what's actually enforced rather than what was planned. GitHub renders
it inline.

Six foreign keys are enforced. Three other relationships exist in the data but
aren't enforced, and the reasons are in that file.

---

## Setup

Needs PostgreSQL 14+ and Python 3.9+.

```bash
createdb olist

python3 -m venv .venv
.venv/bin/pip install psycopg2-binary

.venv/bin/python scripts/load_data.py
psql -d olist -f optimizations.sql
```

The loader builds the schema, downloads about 126 MB of CSVs, streams them in
with `COPY`, then adds foreign keys and indexes. Takes roughly 20 seconds. It
checks every table against known row counts and exits non-zero if anything is off.

```bash
.venv/bin/python scripts/load_data.py --skip-download   # reuse local CSVs
.venv/bin/python scripts/load_data.py --verify-only     # re-check an existing load
DATABASE_URL=postgresql://user:pass@host/olist .venv/bin/python scripts/load_data.py
```

## Running the queries

```bash
for f in queries/*.sql; do psql -d olist -f "$f"; done
```

Each file stands alone and prints labelled results.

---

## Layout

| Path | What's in it |
|---|---|
| `schema.sql` | 9 tables and primary keys, with notes on each |
| `constraints.sql` | Foreign keys and indexes, applied after the bulk load |
| `optimizations.sql` | The two objects that survived measurement |
| `scripts/load_data.py` | Downloads and loads via `COPY FROM STDIN` |
| `queries/01_ranking.sql` | `RANK`, `DENSE_RANK`, `ROW_NUMBER`, `NTILE` |
| `queries/02_trend_analysis.sql` | `LAG`/`LEAD`, moving averages, window frames |
| `queries/03_partition_calculations.sql` | Running totals, cumulative sums, Pareto |
| `queries/04_ctes.sql` | Lifetime value, plus a recursive hierarchy walk |
| `queries/05_joins.sql` | Five-table joins on delivery performance |
| `optimization.md` | Four optimization attempts, two of which failed |
| `INTERVIEW_NOTES.md` | Per-query notes on approach and scaling |
| `docs/erd.md` | ERD from the live catalogue |
| `docs/design/` | Design decisions and profiling notes |

---

## About the data

Kaggle needs a login, so the loader pulls from a public HuggingFace mirror. I
checked it file by file against the row counts of the original release before
using it, and that check runs on every load. A truncated download or a swapped
mirror fails loudly instead of quietly giving wrong answers.

### Quirks I kept rather than cleaned up

Handling these correctly is most of the actual work, so they're documented rather
than scrubbed:

- `customer_id` is issued per order. `customer_unique_id` is the person: 99,441
  vs 96,096. Pick the wrong one and you get 0.00% repeat buyers.
- `order_estimated_delivery_date` is midnight on every row. It's a promised day.
  Comparing timestamps misclassifies 1,292 orders as late.
- `review_id` isn't unique. The primary key is `(review_id, order_id)`.
- Two of 73 product categories have no English translation, so category joins use
  `LEFT JOIN` plus `COALESCE`.
- Zip prefixes are `CHAR(5)`. About 24,000 of them start with a zero.
- `geolocation` has roughly 53 rows per zip prefix. Join it directly and revenue
  comes out 154x too high. Queries use the `geolocation_centroid` view instead.
- November 2016 has no orders at all, so `LAG()` on the raw series compares
  December against October. The trend queries build a date spine to avoid this.
- September and October 2018 have orders but no deliveries, because the export
  was taken before they completed. The analysis window is 2017-01 to 2018-08.

Profiling details are in [docs/design/2026-08-10-design.md](docs/design/2026-08-10-design.md).

---

## Optimization results

Four attempts, measured with `EXPLAIN (ANALYZE, BUFFERS)`, five runs each, median
reported. Two of them failed, and I left the failures in.

| Change | Before | After | Result |
|---|---:|---:|---|
| Materialise geolocation centroids | 117.3 ms | 38.8 ms | 3.0x faster |
| Index `customers.customer_unique_id` | 6.22 ms | 0.568 ms | 11.0x faster |
| Partial index on `orders` | 61.6 ms | 60.2 ms | Planner ignored it, dropped |
| Covering index on `order_items` | 36.6 ms | 41.1 ms | Planner ignored it, dropped |

The failures taught me more than the wins. One query reads 53% of its table, and
past roughly 5-10% a sequential scan beats jumping back and forth to the heap.
The other aggregates 98% of its rows. Indexes speed up selective lookups. They do
nothing when you need most of the table.

The biggest win wasn't an index at all. It was noticing that the same 19,015
centroids were being recalculated from a million rows every time a query ran.

Full write-up, including what would break at 100x the data, is in
[optimization.md](optimization.md).

---

## Correctness checks

- The loader checks all 9 tables against known row counts and exits non-zero on a
  mismatch.
- `04_ctes.sql` Q4 asserts that all five levels of the recursive hierarchy sum to
  the same total. They do: 13,221,498.11 at every level.
- Every query file produces byte-identical output across repeated runs. That's how
  I caught a bug in `01_ranking.sql`, where products tied on units sold were
  swapping positions between runs. `ROW_NUMBER` now has an explicit tiebreak while
  `RANK` and `DENSE_RANK` don't, since adding one there would remove the ties the
  query exists to show.

---

## License

Data: [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), CC BY-NC-SA 4.0.
Code: MIT.
