# SQL Sales Analytics

Advanced analytical SQL on the **Olist Brazilian E-Commerce** dataset — window
functions, CTEs, ranking, trend analysis, and measured query optimization in
PostgreSQL 17.

99,441 orders from 96,096 customers across 3,095 sellers, September 2016 to
October 2018. **1,550,922 rows across 9 tables.**

Every query in this repository has been executed against the real dataset. Every
figure below is measured, not estimated.

---

## Key insights

**1. Late delivery destroys reviews — but early delivery buys nothing.**

| Delivery outcome | Orders | Avg review | 1–2 star |
|---|---:|---:|---:|
| 10+ days early | 61,849 | 4.32 | 8.9% |
| 1–9 days early | 26,795 | 4.23 | 9.9% |
| On the promised day | 1,292 | 4.04 | 12.3% |
| 1–3 days late | 1,870 | 3.29 | 32.2% |
| 4–10 days late | 2,572 | 1.97 | 71.4% |
| More than 10 days late | 2,092 | 1.71 | 78.8% |

Beating the promise by ten days scores 4.32 against 4.23 for beating it by one —
a 0.09 gain for ten days of slack. Missing it by four days costs **2.26 points**,
and one-to-two star reviews rise from 9% to 71%.

The asymmetry argues for *accurate* delivery estimates rather than conservative
ones. Padding every estimate buys almost no goodwill; the entire commercial value
sits in not missing the date you promised.

**6.77% of delivered orders arrived late** (6,534 of 96,470). That figure is
lower than it first appears, and the reason is worth reading: `order_estimated_
delivery_date` is stored at **midnight** for all 99,441 orders, so it records a
promised *day*, not an instant. Comparing full timestamps classifies an order
promised for the 10th and delivered at 09:00 *on* the 10th as late — inflating
the rate to 8.11% and adding 1,292 orders that were never late. All queries here
compare dates.

**2. Revenue is extremely concentrated: 28 sellers produce a quarter of it.**

Of 2,970 sellers with delivered orders, **28 (0.9%) generate 25% of revenue**,
127 (4.3%) generate half, and 533 (17.9%) generate 80%. The bottom decile
contributes 0.1%. Losing a handful of top sellers would be a material commercial
risk.

**3. This is an acquisition business, not a retention business.**

**97% of customers ordered exactly once** (90,557 of 93,358), and repeat
customers account for just **5.5% of revenue**. A retention programme here would
be optimising a 5.5% slice. That finding only appears if you group by
`customer_unique_id` — grouping by `customer_id`, which the schema invites,
reports every customer as a one-time buyer and hides it entirely.

**4. Growth is decelerating, and it was never coming from basket size.**

Year-over-year growth fell from **+727% in January 2018 to +51% by August**.
Average order value declined over the same period, 149 → 132 BRL. Growth came
entirely from order volume. November 2017 remains the standout month at 987,765
BRL — **63.7% above its prior three-month baseline** (Black Friday).

---

## Entity relationship diagram

See **[docs/erd.md](docs/erd.md)** — generated from the live database catalogue,
so it reflects what is actually enforced rather than what was intended. GitHub
renders it inline.

Six foreign keys are enforced. Three relationships that exist in the data are
deliberately *not* enforced, and the reasons are documented in that file — they
are among the more interesting decisions in the schema.

---

## Setup

Requires PostgreSQL 14+ and Python 3.9+.

```bash
createdb olist

python3 -m venv .venv
.venv/bin/pip install psycopg2-binary

.venv/bin/python scripts/load_data.py     # downloads CSVs, loads, verifies
psql -d olist -f optimizations.sql         # materialized view + index
```

The loader creates the schema, downloads ~126 MB of CSVs, streams them in with
`COPY`, then applies foreign keys and indexes. It takes about 20 seconds and
verifies every table against canonical row counts, exiting non-zero on mismatch.

```bash
.venv/bin/python scripts/load_data.py --skip-download   # reuse local CSVs
.venv/bin/python scripts/load_data.py --verify-only     # re-check an existing load
DATABASE_URL=postgresql://user:pass@host/olist .venv/bin/python scripts/load_data.py
```

## Running the queries

```bash
for f in queries/*.sql; do psql -d olist -f "$f"; done
```

Each file is self-contained and prints labelled result sets.

---

## Repository layout

| Path | Contents |
|---|---|
| `schema.sql` | 9 tables and primary keys, each documented with its role and traps |
| `constraints.sql` | Foreign keys and indexes, applied *after* the bulk load |
| `optimizations.sql` | The two objects that earned their place by measurement |
| `scripts/load_data.py` | Downloads and loads via `COPY FROM STDIN` |
| `queries/01_ranking.sql` | `RANK`, `DENSE_RANK`, `ROW_NUMBER`, `NTILE` |
| `queries/02_trend_analysis.sql` | `LAG`/`LEAD`, moving averages, window frames |
| `queries/03_partition_calculations.sql` | Running totals, cumulative sums, Pareto |
| `queries/04_ctes.sql` | Lifetime value, and a recursive hierarchy walk |
| `queries/05_joins.sql` | Five-table joins on delivery performance |
| `optimization.md` | Four measured optimizations — two of which failed |
| `INTERVIEW_NOTES.md` | What each query does, why, and what breaks at 100× |
| `docs/erd.md` | ERD generated from the live catalogue |
| `docs/design/` | Design decisions and data profiling findings |

---

## About the data

Kaggle requires authentication, so the loader pulls from a public HuggingFace
mirror. It was verified file-by-file against the canonical row counts of the
original release, and that check runs on **every** load — a truncated download or
a changed mirror fails loudly rather than silently producing wrong numbers.

### Quirks preserved rather than scrubbed

Handling these correctly is the actual work, so they are kept and documented:

- **`customer_id` is issued per order.** `customer_unique_id` is the person —
  99,441 vs 96,096. Grouping by the wrong one reports 0.00% repeat buyers.
- **`order_estimated_delivery_date` is stored at midnight** for all 99,441 rows.
  It records a promised *day*. Comparing full timestamps classifies orders
  delivered *on* the promised day as late — 1,292 of them.
- **`review_id` is not unique**; the primary key is `(review_id, order_id)`.
- **2 of 73 product categories have no English translation**, so category joins
  are `LEFT JOIN` + `COALESCE`.
- **Zip prefixes are `CHAR(5)`** — 24,000 begin with zero.
- **`geolocation` holds ~53 rows per zip prefix.** Joining it directly inflates
  revenue by 154×. Queries use the `geolocation_centroid` view instead.
- **November 2016 contains zero orders**, so `LAG()` over the raw series compares
  December against October. Every trend query uses a generated date spine.
- **September and October 2018 are right-censored** — orders exist but none were
  delivered when the dataset was extracted. The analysis window is 2017-01 to
  2018-08 for this reason.

Full profiling in [`docs/design/2026-08-10-design.md`](docs/design/2026-08-10-design.md).

---

## Optimization results

Four attempts, measured with `EXPLAIN (ANALYZE, BUFFERS)`, five runs each,
median reported. **Two failed and are documented as failures.**

| Change | Before | After | Result |
|---|---:|---:|---|
| Materialise geolocation centroids | 117.3 ms | 38.8 ms | **3.0× faster** |
| Index `customers.customer_unique_id` | 6.22 ms | 0.568 ms | **11.0× faster** |
| Partial index on `orders` | 61.6 ms | 60.2 ms | Ignored by planner — dropped |
| Covering index on `order_items` | 36.6 ms | 41.1 ms | Ignored by planner — dropped |

The failures are the more instructive half: one query reads 53% of its table
(past roughly 5–10%, a sequential scan beats random heap access) and the other
aggregates 98% of its rows. **Indexes accelerate selective access; they do
nothing for full-table aggregation.**

The largest win was not an index at all — it was noticing that the same 19,015
centroids were being re-derived from a million rows on every execution.

Full analysis, including what breaks at 100× the data volume, in
[`optimization.md`](optimization.md).

---

## Correctness

- The loader verifies all 9 tables against canonical row counts and exits
  non-zero on mismatch.
- `04_ctes.sql` Q4 asserts that all five levels of the recursive hierarchy total
  identically — they do, at 13,221,498.11 each.
- Every query file is verified **byte-reproducible** across repeated runs. This
  is how a latent non-determinism in `01_ranking.sql` was caught: products tied
  on units sold were swapping between runs, so `ROW_NUMBER` now carries an
  explicit tiebreak while `RANK` and `DENSE_RANK` deliberately do not.

---

## License

Data: [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), CC BY-NC-SA 4.0.
Code: MIT.
