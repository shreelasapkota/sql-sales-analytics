-- =============================================================================
-- schema.sql: Olist Brazilian E-Commerce analytics schema
-- =============================================================================
-- Target: PostgreSQL 17
-- Usage:  psql -d olist -f schema.sql
--
-- This script is idempotent: it drops and recreates every object, so it can be
-- re-run freely during development.
--
-- Load order matters. This file creates tables and PRIMARY KEYs only. Foreign
-- keys and indexes are applied by constraints.sql AFTER the bulk COPY, because
-- validating constraints row-by-row during a 1.4M-row load is far slower than
-- validating them once, in bulk, at the end.
-- =============================================================================

DROP TABLE IF EXISTS order_reviews         CASCADE;
DROP TABLE IF EXISTS order_payments        CASCADE;
DROP TABLE IF EXISTS order_items           CASCADE;
DROP TABLE IF EXISTS orders                CASCADE;
DROP TABLE IF EXISTS products              CASCADE;
DROP TABLE IF EXISTS product_category_translation CASCADE;
DROP TABLE IF EXISTS sellers               CASCADE;
DROP TABLE IF EXISTS customers             CASCADE;
DROP TABLE IF EXISTS geolocation           CASCADE;


-- -----------------------------------------------------------------------------
-- customers: one row per *order-placer*, not per person.
-- -----------------------------------------------------------------------------
-- The single most misread table in this dataset. Olist issues a NEW customer_id
-- for every order, so this table has exactly as many rows as `orders` (99,441).
-- The stable identity of a human being is customer_unique_id (96,096 distinct).
--
-- Consequence: COUNT(DISTINCT customer_id) measures ORDERS, not customers, and
-- any repeat-purchase or lifetime-value analysis MUST group by customer_unique_id.
-- Getting this backwards makes every customer look like a one-time buyer.
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id              CHAR(32)    NOT NULL,
    customer_unique_id       CHAR(32)    NOT NULL,
    -- CHAR(5), not INTEGER. 245,733 Brazilian zip prefixes begin with '0';
    -- an integer column would silently turn '01001' into 1001 and break both
    -- the joins to geolocation and the Day 3 prefix-rollup hierarchy.
    customer_zip_code_prefix CHAR(5)     NOT NULL,
    customer_city            TEXT        NOT NULL,
    customer_state           CHAR(2)     NOT NULL,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id)
);

COMMENT ON TABLE  customers IS
    'One row per order-placer. customer_unique_id identifies the actual person; customer_id is per-order.';
COMMENT ON COLUMN customers.customer_unique_id IS
    'Stable person identifier. Use this for retention/LTV, never customer_id.';


-- -----------------------------------------------------------------------------
-- sellers: the marketplace sellers who fulfil order items.
-- -----------------------------------------------------------------------------
-- Small (3,095 rows) but the anchor of all seller-performance ranking. Note that
-- a single order can contain items from several sellers, so seller revenue is
-- only correct when computed from order_items, never from orders.
-- -----------------------------------------------------------------------------
CREATE TABLE sellers (
    seller_id              CHAR(32) NOT NULL,
    seller_zip_code_prefix CHAR(5)  NOT NULL,
    seller_city            TEXT     NOT NULL,
    seller_state           CHAR(2)  NOT NULL,
    CONSTRAINT pk_sellers PRIMARY KEY (seller_id)
);

COMMENT ON TABLE sellers IS
    'Marketplace sellers. One order may span multiple sellers, so join via order_items.';


-- -----------------------------------------------------------------------------
-- product_category_translation: Portuguese to English category names.
-- -----------------------------------------------------------------------------
-- A lookup table, and an incomplete one: it covers 71 categories while products
-- reference 73. `pc_gamer` and `portateis_cozinha_e_preparadores_de_alimentos`
-- have no English name.
--
-- This is why products.product_category_name has NO foreign key to this table:
-- declaring one would fail on those two categories. Queries LEFT JOIN here and
-- COALESCE to the Portuguese name. An INNER JOIN would quietly delete those
-- products' revenue from every report.
--
-- Source file carries a UTF-8 BOM; the loader reads it with encoding utf-8-sig.
-- -----------------------------------------------------------------------------
CREATE TABLE product_category_translation (
    product_category_name         TEXT NOT NULL,
    product_category_name_english TEXT NOT NULL,
    CONSTRAINT pk_product_category_translation PRIMARY KEY (product_category_name)
);

COMMENT ON TABLE product_category_translation IS
    'PT->EN category lookup. INCOMPLETE: 71 of 73 categories. Always LEFT JOIN.';


-- -----------------------------------------------------------------------------
-- products: product dimensions and category assignment.
-- -----------------------------------------------------------------------------
-- 610 of 32,951 products have no category and no descriptive measurements. That
-- is a data fact, not a load error, so those columns are nullable. Ranking
-- queries have to state explicitly whether uncategorised products are included.
-- -----------------------------------------------------------------------------
CREATE TABLE products (
    product_id                 CHAR(32) NOT NULL,
    -- Nullable: 610 products carry no category. No FK to the translation table
    -- (see the comment on product_category_translation above).
    product_category_name      TEXT,
    -- The source CSV misspells these two columns as "lenght". Corrected here on
    -- purpose; the loader maps the misspelled CSV headers onto these names.
    product_name_length        SMALLINT,
    product_description_length INTEGER,
    product_photos_qty         SMALLINT,
    product_weight_g           INTEGER,
    product_length_cm          INTEGER,
    product_height_cm          INTEGER,
    product_width_cm           INTEGER,
    CONSTRAINT pk_products PRIMARY KEY (product_id)
);

COMMENT ON TABLE  products IS
    'Product catalogue. 610 rows have a NULL category. Decide explicitly how to treat them.';
COMMENT ON COLUMN products.product_name_length IS
    'Renamed from the source CSV''s misspelled "product_name_lenght".';


-- -----------------------------------------------------------------------------
-- orders: the order lifecycle. Spine of every time-based query.
-- -----------------------------------------------------------------------------
-- Five timestamps track an order from purchase to delivery. Only
-- order_purchase_timestamp is guaranteed present; the rest are NULL whenever the
-- order did not reach that stage. 2,965 orders never reached the customer.
--
-- Only 96,478 of 99,441 orders are 'delivered'. Revenue queries filter on status
-- on purpose, and delivery-time math must exclude NULL delivery dates rather
-- than coercing them to zero.
-- -----------------------------------------------------------------------------
CREATE TABLE orders (
    order_id                      CHAR(32)  NOT NULL,
    customer_id                   CHAR(32)  NOT NULL,
    order_status                  TEXT      NOT NULL,
    order_purchase_timestamp      TIMESTAMP NOT NULL,
    -- All four nullable by design: an order that was cancelled before shipping
    -- legitimately has no carrier or delivery date.
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP,
    CONSTRAINT pk_orders PRIMARY KEY (order_id)
);

COMMENT ON TABLE  orders IS
    'Order lifecycle. Spans 2016-09-04 to 2018-10-17. Only 96,478 of 99,441 are delivered.';
COMMENT ON COLUMN orders.order_delivered_customer_date IS
    'NULL for 2,965 orders that never arrived. Exclude, do not zero-fill.';


-- -----------------------------------------------------------------------------
-- order_items: line items. THE revenue table.
-- -----------------------------------------------------------------------------
-- Grain: one row per item per order. order_item_id is a sequence within an order
-- (1, 2, 3...), NOT a global id, hence the composite primary key.
--
-- Revenue lives here, not in orders. `price` is per unit of that line, and
-- `freight_value` is shipping apportioned to the line. Item revenue is
-- price + freight_value; product revenue alone is just price. Every ranking and
-- trend query in this project is built on this table.
-- -----------------------------------------------------------------------------
CREATE TABLE order_items (
    order_id            CHAR(32)      NOT NULL,
    order_item_id       SMALLINT      NOT NULL,
    product_id          CHAR(32)      NOT NULL,
    seller_id           CHAR(32)      NOT NULL,
    shipping_limit_date TIMESTAMP     NOT NULL,
    -- NUMERIC, never REAL/DOUBLE. Binary floats cannot represent decimal money
    -- exactly, and the error compounds when summing 112,650 line items.
    price               NUMERIC(10,2) NOT NULL,
    freight_value       NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_order_items PRIMARY KEY (order_id, order_item_id)
);

COMMENT ON TABLE  order_items IS
    'Line items, the revenue grain. One row per item per order. 112,650 rows.';
COMMENT ON COLUMN order_items.order_item_id IS
    'Sequence within an order (1..n), not a global identifier.';


-- -----------------------------------------------------------------------------
-- order_payments: how each order was paid for.
-- -----------------------------------------------------------------------------
-- One order may split across several payment methods (voucher + credit card),
-- so payment_sequential numbers them and forms half the primary key.
--
-- Trap: SUM(payment_value) is NOT the same as SUM(price + freight_value) from
-- order_items. Joining orders to both tables at once fans out rows and inflates
-- both totals. Aggregate each side separately, then join the aggregates.
-- -----------------------------------------------------------------------------
CREATE TABLE order_payments (
    order_id             CHAR(32)      NOT NULL,
    payment_sequential   SMALLINT      NOT NULL,
    payment_type         TEXT          NOT NULL,
    payment_installments SMALLINT      NOT NULL,
    payment_value        NUMERIC(10,2) NOT NULL,
    CONSTRAINT pk_order_payments PRIMARY KEY (order_id, payment_sequential)
);

COMMENT ON TABLE order_payments IS
    'Payments per order; orders may split across methods. Never join alongside order_items without pre-aggregating.';


-- -----------------------------------------------------------------------------
-- order_reviews: customer satisfaction, 1 to 5.
-- -----------------------------------------------------------------------------
-- review_id is NOT unique: 99,224 rows carry only 98,410 distinct review_ids.
-- The pair (review_id, order_id) IS unique, so it is the primary key. Assuming
-- review_id alone was the key would fail the load outright, which is exactly
-- how this was caught.
--
-- 98,673 distinct orders are reviewed, so a few orders have multiple reviews.
-- Averaging review_score after joining to order_items double-counts; pre-aggregate.
-- -----------------------------------------------------------------------------
CREATE TABLE order_reviews (
    review_id               CHAR(32)  NOT NULL,
    order_id                CHAR(32)  NOT NULL,
    review_score            SMALLINT  NOT NULL,
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP NOT NULL,
    review_answer_timestamp TIMESTAMP NOT NULL,
    CONSTRAINT pk_order_reviews PRIMARY KEY (review_id, order_id),
    CONSTRAINT ck_review_score CHECK (review_score BETWEEN 1 AND 5)
);

COMMENT ON TABLE order_reviews IS
    'Review scores 1-5. review_id alone is NOT unique, PK is (review_id, order_id).';


-- -----------------------------------------------------------------------------
-- geolocation: zip prefix to latitude/longitude.
-- -----------------------------------------------------------------------------
-- On purpose has NO primary key. 1,000,163 rows cover only 19,015 distinct zip
-- prefixes, and 261,831 rows are exact duplicates. That is the raw data, loaded
-- faithfully rather than quietly deduplicated.
--
-- Trap: joining this straight onto customers multiplies every customer row by
-- ~53 and inflates revenue by the same factor. Always aggregate to one row per
-- zip prefix first (see queries/05_joins.sql).
--
-- DOUBLE PRECISION for coordinates, not NUMERIC: these are measurements, where
-- approximation is fine and arithmetic is faster. Money gets the opposite treatment.
-- -----------------------------------------------------------------------------
CREATE TABLE geolocation (
    geolocation_zip_code_prefix CHAR(5)          NOT NULL,
    geolocation_lat             DOUBLE PRECISION NOT NULL,
    geolocation_lng             DOUBLE PRECISION NOT NULL,
    geolocation_city            TEXT             NOT NULL,
    geolocation_state           CHAR(2)          NOT NULL
);

COMMENT ON TABLE geolocation IS
    'Zip-prefix coordinates. No PK: ~53 rows per zip, 261,831 exact duplicates. Pre-aggregate before joining.';
