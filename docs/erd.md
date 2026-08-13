# Entity Relationship Diagram

Generated from the live database catalogue (`information_schema`), so it reflects
what is actually enforced rather than what was intended.

Row counts are from `pg_stat_user_tables` after a full load.

```mermaid
erDiagram
    customers ||--o{ orders : "places"
    orders ||--|{ order_items : "contains"
    orders ||--o{ order_payments : "paid by"
    orders ||--o{ order_reviews : "reviewed by"
    products ||--o{ order_items : "sold as"
    sellers ||--o{ order_items : "fulfilled by"

    customers {
        char32 customer_id PK "99,441 — one per ORDER"
        char32 customer_unique_id "96,096 — the actual person"
        char5 customer_zip_code_prefix "CHAR not INT: leading zeros"
        text customer_city
        char2 customer_state
    }

    orders {
        char32 order_id PK "99,441"
        char32 customer_id FK
        text order_status "96,478 delivered"
        timestamp order_purchase_timestamp "2016-09 to 2018-10"
        timestamp order_approved_at "nullable"
        timestamp order_delivered_carrier_date "nullable"
        timestamp order_delivered_customer_date "NULL for 2,965"
        timestamp order_estimated_delivery_date "always midnight"
    }

    order_items {
        char32 order_id PK,FK "112,650 rows"
        smallint order_item_id PK "sequence within order"
        char32 product_id FK
        char32 seller_id FK
        timestamp shipping_limit_date
        numeric price "NUMERIC not FLOAT"
        numeric freight_value
    }

    order_payments {
        char32 order_id PK,FK "103,886 rows"
        smallint payment_sequential PK "orders may split"
        text payment_type
        smallint payment_installments
        numeric payment_value
    }

    order_reviews {
        char32 review_id PK "NOT unique alone"
        char32 order_id PK,FK "99,224 rows / 98,673 orders"
        smallint review_score "1-5, CHECK constraint"
        text review_comment_title
        text review_comment_message
        timestamp review_creation_date
        timestamp review_answer_timestamp
    }

    products {
        char32 product_id PK "32,951"
        text product_category_name "NULL for 610 — no FK"
        smallint product_name_length "renamed from 'lenght'"
        integer product_description_length
        smallint product_photos_qty
        integer product_weight_g
        integer product_length_cm
        integer product_height_cm
        integer product_width_cm
    }

    sellers {
        char32 seller_id PK "3,095"
        char5 seller_zip_code_prefix
        text seller_city
        char2 seller_state
    }

    product_category_translation {
        text product_category_name PK "71 of 73 categories"
        text product_category_name_english
    }

    geolocation {
        char5 geolocation_zip_code_prefix "NO PK — 1,000,163 rows"
        float geolocation_lat
        float geolocation_lng
        text geolocation_city
        char2 geolocation_state
    }

    geolocation_centroid {
        char5 zip PK "19,015 — materialized view"
        float lat
        float lng
        bigint source_rows
    }
```

## What the diagram does not show, and why it matters

Three relationships exist in the data but are deliberately **not** enforced as
foreign keys. Each absence is a decision, not an oversight.

**`products.product_category_name` → `product_category_translation`**
Cannot be a foreign key: products reference 73 categories and the lookup covers
71. `pc_gamer` and `portateis_cozinha_e_preparadores_de_alimentos` have no
English name, so the constraint would fail on load. Queries use `LEFT JOIN` +
`COALESCE`; an inner join would silently delete those products' revenue.

**`customers`/`sellers` zip → `geolocation`**
`geolocation` has no unique key to reference — it holds ~53 rows per zip prefix.
Coverage is also incomplete: 476 delivered orders have a zip absent from the
table. Joins go through `geolocation_centroid` instead, which is unique by
construction.

**`geolocation_centroid` is a materialized view, not a table.** It appears here
because queries join it, but it is derived data with no foreign keys of its own.
See `optimization.md` for the measurement that justified it.

## The relationship that causes the most errors

`customers ||--o{ orders` reads as "one customer places many orders", which is
how this schema *looks*. In practice Olist issues a **new `customer_id` for every
order**, so the relationship is effectively 1:1 — 99,441 customers, 99,441
orders.

The real one-to-many is `customer_unique_id → orders`, and that column is not a
key of anything. Grouping by `customer_id` reports every customer as a one-time
buyer with exactly 1.000 orders each. The ERD cannot show this; only the data can.

## Regenerating

This diagram is committed as Mermaid rather than an image so it stays in version
control, diffs meaningfully, and cannot drift from the schema unnoticed. GitHub
renders it natively.

To produce the pgAdmin version instead:

1. Open **pgAdmin 4** (installed at `~/Applications/pgAdmin 4.app`)
2. Register the server: Host `localhost`, Port `5432`, Database `olist`,
   Username `shsapkota`, no password (local trust auth)
3. Right-click the **`olist`** database → **Generate ERD**
4. **File → Save Image** → `docs/erd.png`

Both can coexist; the pgAdmin export shows the same six enforced foreign keys.
