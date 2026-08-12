-- =============================================================================
-- 05_joins.sql — Multi-table joins: delivery performance by seller and region
-- =============================================================================
-- Target: PostgreSQL 17
-- Run:    psql -d olist -f queries/05_joins.sql
--         (requires optimizations.sql to have been applied — Q3 joins
--          geolocation_centroid rather than the raw geolocation table)
--
-- Conventions from 01_ranking.sql carry over: revenue is SUM(order_items.price),
-- and only delivered orders count.
--
-- HOW "LATE" IS DEFINED HERE, AND WHY IT MATTERS
-- ----------------------------------------------
-- order_estimated_delivery_date is stored at MIDNIGHT for all 99,441 orders —
-- there is not a single non-zero time component in the column. It records a
-- promised *day*, not a promised instant.
--
-- That makes the comparison operator a business decision, not a formatting one:
--
--   timestamp comparison   delivered_customer_date > estimated_delivery_date
--                          -> 7,826 late (8.11%)
--   date comparison        delivered_customer_date::date > estimated::date
--                          -> 6,534 late (6.77%)
--
-- The gap is 1,292 orders — 16.5% of the apparent late total — that arrived ON
-- the promised day but after 00:00. Under the timestamp comparison an order
-- promised for the 10th and delivered at 09:00 on the 10th is "late by 0 days",
-- which is not a coherent thing to report.
--
-- This file uses the DATE comparison throughout: the promise was a day, so
-- arriving on that day is on time. Every "late" figure below is therefore 6.77%,
-- not the 8.11% a naive timestamp comparison produces.
--
-- THE TWO JOIN RULES THIS FILE IS BUILT ON
-- ----------------------------------------
-- 1. NEVER join two child tables to the same parent without pre-aggregating.
--    Measured in Q2: item revenue inflates from 13,221,498 to 13,813,829 and
--    payments from 15,422,462 to 19,776,160 purely from row duplication.
--
-- 2. CHECK THE GRAIN OF EVERY TABLE BEFORE JOINING IT.
--    Raw geolocation holds 1,000,163 rows for 19,015 zip prefixes. Joining it
--    directly multiplies revenue by ~154x (Q3).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Where do late deliveries concentrate?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Which seller states have the worst on-time delivery performance, and how
--   badly do they miss when they miss?
--
-- WHY THIS TECHNIQUE
--   Four tables at two grains. order_items is the bridge between orders and
--   sellers, so the seller dimension is only reachable through it.
--
-- THE GRAIN DECISION THAT MAKES THE AVERAGES CORRECT
--   The CTE below is DISTINCT on (order_id, seller_state), NOT on
--   (order_id, seller_id).
--
--   An earlier version used seller_id. That kept COUNT(DISTINCT order_id)
--   correct, but an order split between two sellers in the SAME state produced
--   two rows — so its delivery time was averaged in twice while counting once.
--   The rates were protected and the averages quietly were not.
--
--   Deduplicating at the grain the query actually reports on (state) fixes both
--   at once. The rule generalises: the CTE grain should match the GROUP BY, or
--   every aggregate has to be individually defended.
--
--   An order spanning two DIFFERENT states still counts once per state, which is
--   intended — either state's logistics could have caused the delay.
-- -----------------------------------------------------------------------------
\echo '=== Q1. Late delivery rate by seller state ==='

WITH order_delivery AS (
    SELECT DISTINCT
        o.order_id,
        s.seller_state,
        o.order_delivered_customer_date::date
            > o.order_estimated_delivery_date::date     AS is_late,
        (o.order_delivered_customer_date::date
            - o.order_purchase_timestamp::date)         AS days_to_deliver,
        (o.order_delivered_customer_date::date
            - o.order_estimated_delivery_date::date)    AS days_vs_promise
    FROM orders      o
    JOIN order_items oi ON oi.order_id  = o.order_id
    JOIN sellers     s  ON s.seller_id  = oi.seller_id
    WHERE o.order_status = 'delivered'
      -- Eight orders carry status 'delivered' with a NULL delivery date —
      -- contradictory source data. A NULL comparison is neither true nor false,
      -- so excluding them explicitly keeps the denominator honest rather than
      -- letting NULL semantics decide silently.
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    seller_state,
    COUNT(*)                                  AS orders,
    COUNT(*) FILTER (WHERE is_late)           AS late_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 2) AS pct_late,
    ROUND(AVG(days_to_deliver), 1)            AS avg_days_to_deliver,
    -- Averaged over late orders only. Including on-time orders would mix in
    -- negative values (early deliveries) and understate the failures.
    ROUND(AVG(days_vs_promise) FILTER (WHERE is_late), 1) AS avg_days_late
FROM order_delivery
GROUP BY seller_state
HAVING COUNT(*) >= 300
ORDER BY pct_late DESC;


-- -----------------------------------------------------------------------------
-- Query 2 — The fan-out trap: joining two child tables at once
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   What did customers pay, and what did the merchandise cost? Both facts live
--   in different children of `orders`.
--
-- WHY THIS TECHNIQUE
--   This query exists to show the wrong answer next to the right one.
--
--   order_items and order_payments are BOTH children of orders. Joining both in
--   one FROM clause produces the CARTESIAN PRODUCT per order: an order with 3
--   items and 2 payments yields 6 rows, each item price counted twice and each
--   payment three times.
--
--   Nothing errors. Both totals simply come out too high, and stay plausible
--   enough to survive review.
--
--   The fix is to aggregate each child to one row per order FIRST, then join the
--   aggregates. Each CTE below is at order grain, so the join is 1:1.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q2. Fan-out: naive multi-child join vs pre-aggregated join ==='

WITH naive AS (
    SELECT
        SUM(oi.price)        AS item_revenue,
        SUM(p.payment_value) AS payment_total,
        COUNT(*)             AS row_count
    FROM orders         o
    JOIN order_items    oi ON oi.order_id = o.order_id
    JOIN order_payments p  ON p.order_id  = o.order_id
    WHERE o.order_status = 'delivered'
),
items_per_order AS (
    SELECT order_id, SUM(price) AS item_revenue
    FROM order_items
    GROUP BY order_id
),
payments_per_order AS (
    SELECT order_id, SUM(payment_value) AS payment_total
    FROM order_payments
    GROUP BY order_id
),
correct AS (
    SELECT
        SUM(i.item_revenue)   AS item_revenue,
        SUM(pp.payment_total) AS payment_total,
        COUNT(*)              AS row_count
    FROM orders o
    JOIN items_per_order i ON i.order_id = o.order_id
    -- LEFT JOIN because not every order has a payment row; an inner join would
    -- silently drop those orders from the item revenue total too.
    LEFT JOIN payments_per_order pp ON pp.order_id = o.order_id
    WHERE o.order_status = 'delivered'
)
SELECT 'WRONG: both children joined directly' AS method,
       row_count, ROUND(item_revenue, 2) AS item_revenue_brl,
       ROUND(payment_total, 2) AS payment_total_brl
FROM naive
UNION ALL
SELECT 'CORRECT: each child pre-aggregated',
       row_count, ROUND(item_revenue, 2), ROUND(payment_total, 2)
FROM correct;


-- -----------------------------------------------------------------------------
-- Query 3 — Does distance explain late delivery?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Does the physical distance between seller and customer predict lateness?
--
-- WHY THIS TECHNIQUE
--   Three separate correctness problems had to be solved before this question
--   could be answered at all.
--
--   1. THE GEOLOCATION GRAIN.
--      Raw geolocation has ~53 rows per zip prefix. Joining it directly
--      multiplies revenue by 154x (13.2M -> 2.03bn) and row count from 110,197
--      to 16,842,720. This query joins geolocation_centroid instead — one row
--      per zip, built by optimizations.sql — which makes the join 1:1 by
--      construction. That is a correctness fix that happens to also be 3.2x
--      faster; see optimization.md.
--
--   2. MULTI-SELLER ORDERS LANDING IN SEVERAL DISTANCE BANDS.
--      An order with items from two sellers has two distances. An earlier
--      version banded each (order, seller) pair separately, so one order was
--      counted in two bands and the `orders` column summed to more than the
--      96,470 delivered orders.
--
--      Resolved by collapsing to ONE ROW PER ORDER using MAX(distance): an order
--      is not complete until its furthest-travelling item arrives, so the
--      longest leg is what the customer actually waits for.
--
--   3. INCOMPLETE ZIP COVERAGE.
--      Not every zip prefix appears in geolocation. LEFT JOIN is used and the
--      unmatched orders are COUNTED AND REPORTED rather than silently dropped —
--      264 orders have an unmapped customer zip and 217 an unmapped seller zip.
--      An inner join would have quietly removed them, which is the same hidden
--      self-selection Q4 warns about.
--
--   Distance uses the haversine formula, not a Pythagorean difference of
--   degrees. A degree of longitude is not a fixed distance — it shrinks towards
--   the poles — and Brazil spans 33 degrees of latitude, so the error would be
--   large and systematically biased by region.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q3. Does distance explain lateness? (one row per order) ==='

WITH order_distance AS (
    SELECT
        o.order_id,
        MAX(o.order_delivered_customer_date::date
            - o.order_purchase_timestamp::date)      AS days_to_deliver,
        -- Every row of an order shares the same lateness, so bool_or simply
        -- collapses the duplicates rather than combining different values.
        bool_or(o.order_delivered_customer_date::date
                > o.order_estimated_delivery_date::date) AS is_late,
        -- The longest leg determines when the order is complete.
        MAX(2 * 6371 * asin(sqrt(
              power(sin(radians(cg.lat - sg.lat) / 2), 2)
            + cos(radians(sg.lat)) * cos(radians(cg.lat))
            * power(sin(radians(cg.lng - sg.lng) / 2), 2)
        ))) AS max_distance_km
    FROM orders      o
    JOIN customers   c  ON c.customer_id = o.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    JOIN sellers     s  ON s.seller_id   = oi.seller_id
    -- LEFT so unmapped zips survive to be counted rather than vanishing.
    LEFT JOIN geolocation_centroid cg ON cg.zip = c.customer_zip_code_prefix
    LEFT JOIN geolocation_centroid sg ON sg.zip = s.seller_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
    GROUP BY o.order_id
)
SELECT
    CASE
        WHEN max_distance_km IS NULL THEN 'z. zip not in geolocation'
        WHEN max_distance_km <   50  THEN 'a. under 50 km'
        WHEN max_distance_km <  200  THEN 'b. 50-200 km'
        WHEN max_distance_km <  500  THEN 'c. 200-500 km'
        WHEN max_distance_km < 1000  THEN 'd. 500-1000 km'
        ELSE                              'e. over 1000 km'
    END                                        AS distance_band,
    COUNT(*)                                   AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_orders,
    ROUND(AVG(days_to_deliver), 1)             AS avg_days_to_deliver,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_late) / COUNT(*), 2) AS pct_late
FROM order_distance
GROUP BY distance_band
ORDER BY distance_band;


-- -----------------------------------------------------------------------------
-- Query 4 — Does late delivery actually cost us review scores?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Late deliveries are assumed to damage reviews. By how much, and is there any
--   reward for arriving early?
--
-- WHY THIS TECHNIQUE
--   Reviews are a THIRD child of orders, so the same fan-out rule applies:
--   98,673 distinct orders carry 99,224 review rows. Pre-aggregating to one
--   score per order stops multiply-reviewed orders being weighted twice.
--
--   LEFT JOIN, not INNER: not every order was reviewed. An inner join would
--   silently restrict the analysis to reviewed orders — a self-selecting
--   population, and exactly the sort of hidden filter that makes a result
--   confidently wrong. Unreviewed orders are counted in their own column.
--
--   Buckets use days_vs_promise, which is now on the same date basis as is_late,
--   so 'on time' and '0 days late' can no longer both be true of one order.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q4. Review scores by delivery outcome ==='

WITH review_per_order AS (
    SELECT order_id, AVG(review_score::numeric) AS review_score
    FROM order_reviews
    GROUP BY order_id
),
order_outcome AS (
    SELECT
        o.order_id,
        (o.order_delivered_customer_date::date
            - o.order_estimated_delivery_date::date) AS days_vs_promise,
        r.review_score
    FROM orders o
    LEFT JOIN review_per_order r ON r.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    CASE
        WHEN days_vs_promise <= -10 THEN 'a. 10+ days early'
        WHEN days_vs_promise <   0  THEN 'b. 1-9 days early'
        WHEN days_vs_promise =    0 THEN 'c. on the promised day'
        WHEN days_vs_promise <=   3 THEN 'd. 1-3 days late'
        WHEN days_vs_promise <=  10 THEN 'e. 4-10 days late'
        ELSE                             'f. more than 10 days late'
    END                                        AS delivery_outcome,
    COUNT(*)                                   AS orders,
    COUNT(review_score)                        AS orders_reviewed,
    COUNT(*) - COUNT(review_score)             AS orders_not_reviewed,
    ROUND(AVG(review_score), 2)                AS avg_review_score,
    ROUND(100.0 * COUNT(*) FILTER (WHERE review_score <= 2)
                / NULLIF(COUNT(review_score), 0), 1) AS pct_scoring_1_or_2
FROM order_outcome
GROUP BY delivery_outcome
ORDER BY delivery_outcome;


-- -----------------------------------------------------------------------------
-- Query 5 — Which sellers are the worst offenders?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Which high-volume sellers have the worst on-time record, and what revenue is
--   exposed to the churn that late delivery causes?
--
-- WHY THIS TECHNIQUE
--   The operational payoff: five tables joined into a list an account manager
--   could act on tomorrow.
--
--   Every child table is pre-aggregated to order grain before joining, so no
--   measure can be double-counted. seller_revenue is computed separately from
--   the order-level lateness flags because the two live at different grains;
--   MAX() retrieves it safely since it is constant per seller.
--
--   The volume threshold exists because a seller with 4 orders and 2 late shows
--   a 50% failure rate and no commercial significance. Percentages on tiny
--   denominators are the most common way a ranking gets hijacked by noise.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q5. Worst on-time performance among high-volume sellers ==='

WITH review_per_order AS (
    SELECT order_id, AVG(review_score::numeric) AS review_score
    FROM order_reviews
    GROUP BY order_id
),
seller_orders AS (
    SELECT DISTINCT
        oi.seller_id,
        o.order_id,
        o.order_delivered_customer_date::date
            > o.order_estimated_delivery_date::date AS is_late
    FROM orders      o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
),
seller_revenue AS (
    SELECT oi.seller_id, SUM(oi.price) AS revenue
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
)
SELECT
    LEFT(so.seller_id, 8)                   AS seller,
    s.seller_state,
    COUNT(*)                                AS orders,
    COUNT(*) FILTER (WHERE so.is_late)      AS late_orders,
    ROUND(100.0 * COUNT(*) FILTER (WHERE so.is_late) / COUNT(*), 1) AS pct_late,
    ROUND(AVG(r.review_score), 2)           AS avg_review_score,
    ROUND(MAX(sr.revenue), 2)               AS seller_revenue_brl
FROM seller_orders so
JOIN sellers        s  ON s.seller_id  = so.seller_id
JOIN seller_revenue sr ON sr.seller_id = so.seller_id
LEFT JOIN review_per_order r ON r.order_id = so.order_id
GROUP BY so.seller_id, s.seller_state
HAVING COUNT(*) >= 100
ORDER BY pct_late DESC
LIMIT 15;
