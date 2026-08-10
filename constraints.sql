-- =============================================================================
-- constraints.sql — foreign keys and indexes, applied AFTER the bulk load
-- =============================================================================
-- Target: PostgreSQL 17
-- Usage:  psql -d olist -f constraints.sql   (run only once data is loaded)
--
-- WHY THIS IS A SEPARATE FILE
-- ---------------------------
-- If foreign keys exist during a COPY, PostgreSQL fires a referential-integrity
-- trigger for every inserted row — 1.4M trigger firings across this dataset.
-- Adding the constraint afterwards instead validates the whole table in one pass,
-- which can use a hash or merge join over sorted data.
--
-- Same logic for indexes: building an index once over a finished table is
-- cheaper than incrementally maintaining it through every inserted row.
--
-- WHAT IS DELIBERATELY *NOT* HERE
-- -------------------------------
-- Only primary keys (in schema.sql) and single-column foreign-key indexes are
-- created. Composite and covering indexes are held back for the Day 3
-- optimization pass, so EXPLAIN ANALYZE shows genuine before/after improvements
-- rather than pre-staged ones.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Foreign keys
-- -----------------------------------------------------------------------------
-- Data profiling confirmed ZERO orphan rows on every relationship below, so all
-- of these are enforced for real rather than documented and hoped for.
--
-- Two relationships are intentionally absent:
--   * products.product_category_name -> product_category_translation
--     would fail: 2 of 73 categories have no translation row.
--   * geolocation zip -> customers/sellers zip
--     geolocation has no unique key to reference, and zip coverage is partial.
-- -----------------------------------------------------------------------------

ALTER TABLE orders
    ADD CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id) REFERENCES customers (customer_id);

ALTER TABLE order_items
    ADD CONSTRAINT fk_order_items_order
    FOREIGN KEY (order_id) REFERENCES orders (order_id);

ALTER TABLE order_items
    ADD CONSTRAINT fk_order_items_product
    FOREIGN KEY (product_id) REFERENCES products (product_id);

ALTER TABLE order_items
    ADD CONSTRAINT fk_order_items_seller
    FOREIGN KEY (seller_id) REFERENCES sellers (seller_id);

ALTER TABLE order_payments
    ADD CONSTRAINT fk_order_payments_order
    FOREIGN KEY (order_id) REFERENCES orders (order_id);

ALTER TABLE order_reviews
    ADD CONSTRAINT fk_order_reviews_order
    FOREIGN KEY (order_id) REFERENCES orders (order_id);


-- -----------------------------------------------------------------------------
-- Foreign-key indexes
-- -----------------------------------------------------------------------------
-- PostgreSQL automatically indexes the *referenced* side of a foreign key (it is
-- already a primary key) but NOT the referencing side. Without these, every join
-- from a child table back to its parent is a sequential scan, and any future
-- DELETE on a parent has to scan the whole child table to check for references.
--
-- order_items.order_id needs no separate index: it is the leading column of the
-- primary key (order_id, order_item_id), so the PK index already serves it.
-- The same applies to order_payments.order_id.
-- -----------------------------------------------------------------------------

CREATE INDEX idx_orders_customer_id     ON orders      (customer_id);
CREATE INDEX idx_order_items_product_id ON order_items (product_id);
CREATE INDEX idx_order_items_seller_id  ON order_items (seller_id);
CREATE INDEX idx_order_reviews_order_id ON order_reviews (order_id);


-- -----------------------------------------------------------------------------
-- Planner statistics
-- -----------------------------------------------------------------------------
-- ANALYZE refreshes the statistics the query planner uses to estimate row counts.
-- Immediately after a bulk load, those statistics are stale or absent, and the
-- planner will make bad choices — typically nested loops over what it thinks are
-- tiny tables. Running this is what makes the Day 3 EXPLAIN ANALYZE numbers
-- trustworthy rather than artefacts of a cold catalogue.
-- -----------------------------------------------------------------------------

ANALYZE customers;
ANALYZE sellers;
ANALYZE products;
ANALYZE product_category_translation;
ANALYZE orders;
ANALYZE order_items;
ANALYZE order_payments;
ANALYZE order_reviews;
ANALYZE geolocation;
