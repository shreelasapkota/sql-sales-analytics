# SQL Sales Analytics

Advanced analytical SQL on the **Olist Brazilian E-Commerce** dataset — window
functions, CTEs, ranking, trend analysis, and query optimization in PostgreSQL 17.

~100k orders placed on a Brazilian marketplace between September 2016 and
October 2018, loaded across 9 tables and 1.55M rows.

> **Status:** in progress. Schema, loader and ranking queries are complete.
> Trend analysis, partition calculations, CTEs, joins, optimization notes and the
> ERD are still to come. This README is expanded as those land.

## Setup

Requires PostgreSQL 14+ and Python 3.9+.

```bash
# 1. Create the database
createdb olist

# 2. Set up the Python environment
python3 -m venv .venv
.venv/bin/pip install psycopg2-binary

# 3. Download the CSVs and load everything
.venv/bin/python scripts/load_data.py
```

The loader creates the schema, downloads ~126 MB of CSVs into `data/raw/`,
streams them in with `COPY`, then applies foreign keys and indexes. It takes
about 20 seconds and verifies every table against the canonical row counts
before exiting.

```bash
.venv/bin/python scripts/load_data.py --skip-download   # reuse local CSVs
.venv/bin/python scripts/load_data.py --verify-only     # re-check an existing load
```

Point it elsewhere with `DATABASE_URL`:

```bash
DATABASE_URL=postgresql://user:pass@host:5432/olist .venv/bin/python scripts/load_data.py
```

## Running the queries

```bash
psql -d olist -f queries/01_ranking.sql
```

## Repository layout

| Path | Contents |
|---|---|
| `schema.sql` | Table definitions and primary keys, with each table's role documented |
| `constraints.sql` | Foreign keys and indexes, applied after the bulk load |
| `scripts/load_data.py` | Downloads the CSVs and loads them via `COPY FROM STDIN` |
| `queries/01_ranking.sql` | Top-N analysis: `RANK`, `DENSE_RANK`, `ROW_NUMBER`, `NTILE` |
| `docs/design/` | Design decisions and data profiling findings |

## About the data

Kaggle requires authentication, so the loader pulls from a public HuggingFace
mirror. It was verified file-by-file against the canonical row counts of the
original Kaggle release, and that check runs on every load — a truncated
download or a changed mirror fails loudly rather than silently producing wrong
numbers.

Several quirks in this dataset are preserved rather than scrubbed, because
handling them correctly is the actual work:

- `customer_id` is issued **per order**. `customer_unique_id` identifies the
  person — 99,441 vs 96,096.
- `review_id` is **not unique**; the primary key is `(review_id, order_id)`.
- 2 of 73 product categories have **no English translation**, so category joins
  are `LEFT JOIN` + `COALESCE`.
- Zip prefixes are stored as `CHAR(5)` because 24k of them **begin with zero**.
- `geolocation` holds 261,831 duplicate rows and ~53 rows per zip prefix, so it
  must be pre-aggregated before joining.

Full details in [`docs/design/2026-08-10-design.md`](docs/design/2026-08-10-design.md).

## Key insights

Findings so far. Expanded as further queries land.

**Revenue is extremely concentrated among sellers.** The top 10% of sellers
(297 of 2,970) generate **67.1%** of marketplace revenue, and the top 30%
generate 90.1%. The bottom decile contributes 0.1%. Losing a handful of top
sellers would be a material commercial risk.

**Ranking by units and ranking by revenue are different questions.** In
telephony, two products tied at exactly 53 units sold earned 10,854 and 14,818
BRL respectively — a 36% gap. Any "best seller" report has to state which metric
it means.

**Regional demand genuinely differs.** São Paulo and Rio Grande do Sul lead with
`bed_bath_table`, Rio de Janeiro and the Federal District with `watches_gifts`,
and the northeastern states with `health_beauty`. No single category leads
nationally, which argues against uniform inventory placement.

## License

Data: [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), CC BY-NC-SA 4.0.
