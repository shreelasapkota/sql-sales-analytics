#!/usr/bin/env python3
"""Download the Olist dataset and load it into PostgreSQL.

Usage
-----
    python scripts/load_data.py                 # download if needed, then load
    python scripts/load_data.py --skip-download # reuse data/raw/
    python scripts/load_data.py --verify-only   # just re-run the row-count checks

The database URL comes from $DATABASE_URL, defaulting to a local `olist` database.

Design notes
------------
Loading runs as:  schema.sql -> COPY every table -> constraints.sql

Foreign keys and indexes are applied only after the data is in. During a COPY,
an existing foreign key fires a referential-integrity trigger per row (1.4M of
them here), and every index has to be maintained incrementally. Validating and
building once at the end is significantly faster.

Rows are streamed to PostgreSQL with COPY ... FROM STDIN rather than INSERT.
COPY uses a single bulk path into the table and writes far less WAL than
1.4M individual INSERTs, which is the difference between seconds and minutes.

The CSVs are never committed to git. At ~126 MB, dominated by the 61 MB
geolocation file. This script is the reproducible way to obtain them.
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import psycopg2

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

REPO_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = REPO_ROOT / "data" / "raw"

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql:///olist")

# Kaggle requires authentication, so we pull from a public HuggingFace mirror.
# This mirror was verified file-by-file against the canonical Kaggle row counts
# (see EXPECTED_ROWS) before being adopted. That check runs on every load.
MIRROR_BASE = (
    "https://huggingface.co/datasets/"
    "aviahYadler/Olist_Ecommerce_Dataset/resolve/main"
)

# Canonical row counts from the original Kaggle release. The load fails loudly
# if any table does not match, so a truncated download or a without warning changed
# mirror can never masquerade as a successful load.
EXPECTED_ROWS = {
    "customers": 99_441,
    "geolocation": 1_000_163,
    "order_items": 112_650,
    "order_payments": 103_886,
    "order_reviews": 99_224,
    "orders": 99_441,
    "products": 32_951,
    "sellers": 3_095,
    "product_category_translation": 71,
}


class Table:
    """One source CSV and the table it loads into.

    Attributes
    ----------
    name:      destination table name
    csv_stem:  source filename without the .csv extension
    columns:   destination columns, in COPY order
    csv_fields:source CSV headers, positionally matched to `columns`
    encoding:  source file encoding
    """

    def __init__(self, name, csv_stem, columns, csv_fields=None, encoding="utf-8"):
        self.name = name
        self.csv_stem = csv_stem
        self.columns = columns
        # Defaults to identical names; overridden where the CSV header differs
        # from the column we want (see `products`).
        self.csv_fields = csv_fields or columns
        self.encoding = encoding

    @property
    def path(self) -> Path:
        return RAW_DIR / f"{self.csv_stem}.csv"

    @property
    def url(self) -> str:
        return f"{MIRROR_BASE}/{self.csv_stem}.csv"


# Order matters: parents load before children so that constraints.sql can apply
# foreign keys afterwards without reordering anything.
TABLES = [
    Table(
        "customers",
        "olist_customers_dataset",
        ["customer_id", "customer_unique_id", "customer_zip_code_prefix",
         "customer_city", "customer_state"],
    ),
    Table(
        "sellers",
        "olist_sellers_dataset",
        ["seller_id", "seller_zip_code_prefix", "seller_city", "seller_state"],
    ),
    Table(
        # This CSV is written with a UTF-8 BOM. Read as plain utf-8 the first
        # header becomes "﻿product_category_name" and the lookup without warning
        # produces NULLs, so it is decoded as utf-8-sig.
        "product_category_translation",
        "product_category_name_translation",
        ["product_category_name", "product_category_name_english"],
        encoding="utf-8-sig",
    ),
    Table(
        "products",
        "olist_products_dataset",
        ["product_id", "product_category_name", "product_name_length",
         "product_description_length", "product_photos_qty", "product_weight_g",
         "product_length_cm", "product_height_cm", "product_width_cm"],
        # The source misspells "length" as "lenght" in two headers. The schema
        # uses the correct spelling, so the mapping is made explicit here rather
        # than propagating a typo into every downstream query.
        csv_fields=["product_id", "product_category_name", "product_name_lenght",
                    "product_description_lenght", "product_photos_qty",
                    "product_weight_g", "product_length_cm", "product_height_cm",
                    "product_width_cm"],
    ),
    Table(
        "orders",
        "olist_orders_dataset",
        ["order_id", "customer_id", "order_status", "order_purchase_timestamp",
         "order_approved_at", "order_delivered_carrier_date",
         "order_delivered_customer_date", "order_estimated_delivery_date"],
    ),
    Table(
        "order_items",
        "olist_order_items_dataset",
        ["order_id", "order_item_id", "product_id", "seller_id",
         "shipping_limit_date", "price", "freight_value"],
    ),
    Table(
        "order_payments",
        "olist_order_payments_dataset",
        ["order_id", "payment_sequential", "payment_type",
         "payment_installments", "payment_value"],
    ),
    Table(
        "order_reviews",
        "olist_order_reviews_dataset",
        ["review_id", "order_id", "review_score", "review_comment_title",
         "review_comment_message", "review_creation_date",
         "review_answer_timestamp"],
    ),
    Table(
        "geolocation",
        "olist_geolocation_dataset",
        ["geolocation_zip_code_prefix", "geolocation_lat", "geolocation_lng",
         "geolocation_city", "geolocation_state"],
    ),
]


# --------------------------------------------------------------------------- #
# Download
# --------------------------------------------------------------------------- #

def download_all(force: bool = False) -> None:
    """Fetch any CSV not already present in data/raw/."""
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    for table in TABLES:
        if table.path.exists() and not force:
            size_mb = table.path.stat().st_size / 1_048_576
            print(f"  cached   {table.csv_stem}.csv ({size_mb:.1f} MB)")
            continue

        print(f"  fetching {table.csv_stem}.csv ...", end="", flush=True)
        try:
            # Download to a temporary path first so an interrupted transfer can
            # never leave a truncated file that looks cached on the next run.
            tmp = table.path.with_suffix(".csv.part")
            urllib.request.urlretrieve(table.url, tmp)
            tmp.replace(table.path)
        except urllib.error.URLError as exc:
            print(" FAILED")
            sys.exit(f"\nCould not download {table.url}\n  {exc}")

        size_mb = table.path.stat().st_size / 1_048_576
        print(f" done ({size_mb:.1f} MB)")


# --------------------------------------------------------------------------- #
# Load
# --------------------------------------------------------------------------- #

def csv_to_copy_buffer(table: Table) -> tuple[io.StringIO, int]:
    """Reshape one CSV into a tab-delimited buffer ready for COPY.

    Two things have to happen between the CSV and PostgreSQL:

    1. Columns are selected and reordered to match `table.columns`, which is how
       the `products` typo is corrected without editing the source file.
    2. Empty strings become \\N (the COPY NULL marker). Left as-is, an empty
       field would be loaded as the empty string, and `''::numeric` fails
       outright, this is what makes the 610 category-less products and the
       2,965 undelivered orders load correctly as NULL.

    The reshaped data is buffered in memory. At 126 MB that is comfortable and
    keeps the code readable; the note in optimization.md covers what would change
    at 100x this volume.
    """
    # Fields are joined with tabs directly rather than via csv.writer. A writer
    # configured with escapechar="\\" would re-escape the \N NULL marker into a
    # literal \\N, which COPY reads as the two-character string rather than NULL.
    # Escaping is done explicitly below instead.
    buf = io.StringIO()
    rows = 0

    with open(table.path, newline="", encoding=table.encoding) as fh:
        reader = csv.DictReader(fh)

        missing = set(table.csv_fields) - set(reader.fieldnames or [])
        if missing:
            sys.exit(
                f"{table.csv_stem}.csv is missing expected column(s): "
                f"{sorted(missing)}\nFound: {reader.fieldnames}"
            )

        for record in reader:
            out = []
            for field in table.csv_fields:
                value = record[field]
                if value is None or value == "":
                    out.append("\\N")
                else:
                    # Tabs, newlines and backslashes appear inside review comment
                    # text. Escaping them keeps the tab-delimited framing intact;
                    # without this, a single review with a newline would shift
                    # every subsequent column by one.
                    out.append(
                        value.replace("\\", "\\\\")
                             .replace("\t", "\\t")
                             .replace("\n", "\\n")
                             .replace("\r", "\\r")
                    )
            buf.write("\t".join(out))
            buf.write("\n")
            rows += 1

    buf.seek(0)
    return buf, rows


def run_sql_file(cur, path: Path) -> None:
    print(f"  applying {path.name} ...", end="", flush=True)
    cur.execute(path.read_text())
    print(" done")


def load(skip_download: bool = False) -> None:
    if not skip_download:
        print("\n[1/4] Downloading CSVs")
        download_all()
    else:
        print("\n[1/4] Skipping download (--skip-download)")

    conn = psycopg2.connect(DATABASE_URL)
    # One transaction for the whole load. A failure at any point rolls the
    # database back to empty rather than leaving a half-populated schema that
    # later queries would quietly report wrong numbers from.
    conn.autocommit = False

    try:
        with conn.cursor() as cur:
            print("\n[2/4] Creating schema")
            run_sql_file(cur, REPO_ROOT / "schema.sql")

            print("\n[3/4] Loading tables")
            total_rows = 0
            for table in TABLES:
                started = time.perf_counter()
                buf, rows = csv_to_copy_buffer(table)

                cur.copy_expert(
                    f"COPY {table.name} ({', '.join(table.columns)}) "
                    f"FROM STDIN WITH (FORMAT text, NULL '\\N')",
                    buf,
                )

                elapsed = time.perf_counter() - started
                total_rows += rows
                print(f"  {table.name:<28} {rows:>9,} rows  {elapsed:6.2f}s")

            print(f"  {'TOTAL':<28} {total_rows:>9,} rows")

            print("\n[4/4] Applying constraints and indexes")
            run_sql_file(cur, REPO_ROOT / "constraints.sql")

        conn.commit()
        print("\nCommitted.")
    except Exception:
        conn.rollback()
        print("\nLoad failed, transaction rolled back, database left unchanged.")
        raise
    finally:
        conn.close()


# --------------------------------------------------------------------------- #
# Verification
# --------------------------------------------------------------------------- #

def verify() -> bool:
    """Compare loaded row counts against the canonical Kaggle figures."""
    print("\nVerifying row counts against the canonical Kaggle release")
    ok = True

    with psycopg2.connect(DATABASE_URL) as conn, conn.cursor() as cur:
        for name, expected in EXPECTED_ROWS.items():
            cur.execute(f"SELECT COUNT(*) FROM {name}")
            actual = cur.fetchone()[0]
            match = actual == expected
            ok &= match
            print(f"  {'OK  ' if match else 'FAIL'} {name:<30} "
                  f"{actual:>9,} (expected {expected:,})")

        # Spot-check the two traps that a row count alone cannot catch: leading
        # zeros surviving in zip prefixes, and NULLs landing as NULL.
        print("\nData integrity spot-checks")
        checks = [
            ("zip prefixes retaining a leading zero",
             "SELECT COUNT(*) FROM customers WHERE customer_zip_code_prefix LIKE '0%'",
             lambda v: v > 0),
            ("products with NULL category",
             "SELECT COUNT(*) FROM products WHERE product_category_name IS NULL",
             lambda v: v == 610),
            ("orders never delivered (NULL delivery date)",
             "SELECT COUNT(*) FROM orders WHERE order_delivered_customer_date IS NULL",
             lambda v: v == 2965),
            ("distinct people (customer_unique_id)",
             "SELECT COUNT(DISTINCT customer_unique_id) FROM customers",
             lambda v: v == 96096),
            ("categories lacking an English translation",
             """SELECT COUNT(DISTINCT p.product_category_name)
                  FROM products p
                  LEFT JOIN product_category_translation t
                         ON t.product_category_name = p.product_category_name
                 WHERE p.product_category_name IS NOT NULL
                   AND t.product_category_name IS NULL""",
             lambda v: v == 2),
        ]
        for label, sql, predicate in checks:
            cur.execute(sql)
            value = cur.fetchone()[0]
            passed = predicate(value)
            ok &= passed
            print(f"  {'OK  ' if passed else 'FAIL'} {label:<45} {value:>9,}")

    print("\nAll checks passed." if ok else "\nSome checks FAILED.")
    return ok


# --------------------------------------------------------------------------- #

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-download", action="store_true",
                        help="reuse the CSVs already in data/raw/")
    parser.add_argument("--verify-only", action="store_true",
                        help="only re-run the row-count and integrity checks")
    args = parser.parse_args()

    if args.verify_only:
        sys.exit(0 if verify() else 1)

    started = time.perf_counter()
    load(skip_download=args.skip_download)
    ok = verify()
    print(f"\nCompleted in {time.perf_counter() - started:.1f}s")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
