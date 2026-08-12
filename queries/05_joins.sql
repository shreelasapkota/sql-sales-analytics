-- =============================================================================
-- 05_joins.sql — Multi-table joins: delivery performance by seller and region
-- =============================================================================
-- Target: PostgreSQL 17
-- Run:    psql -d olist -f queries/05_joins.sql
--
-- Conventions from 01_ranking.sql carry over: revenue is SUM(order_items.price),
-- and only delivered orders count.
--
-- THE BUSINESS PROBLEM
-- --------------------
-- 8.11% of delivered orders arrived after their promised date (7,826 of 96,470).
-- Late delivery is the strongest driver of bad reviews on a marketplace, so the
-- question is where the failures concentrate: which sellers, which routes,
-- which distances.
--
-- Answering it needs orders, order_items, sellers, customers and reviews joined
-- together — five tables at three different grains. That is exactly where joins
-- go wrong quietly, so this file leads with the failure modes.
--
-- THE TWO RULES THIS FILE IS BUILT ON
-- -----------------------------------
-- 1. NEVER join two child tables to the same parent without pre-aggregating.
--    orders has 1 row per order, order_items has ~1.13, order_payments has
--    ~1.04. Join all three and every order produces items x payments rows, and
--    BOTH sums inflate. Measured in Q2: item revenue jumps from 13,221,498 to
--    13,813,829 purely from row duplication.
--
-- 2. CHECK THE GRAIN OF EVERY TABLE BEFORE JOINING IT.
--    geolocation holds 1,000,163 rows for 19,015 zip prefixes — roughly 53 rows
--    each. Joining it directly multiplies revenue by about 154x, as Q3 shows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Where do late deliveries concentrate?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Which seller states and customer states have the worst on-time delivery
--   performance, and is lateness about distance or about the seller?
--
-- WHY THIS TECHNIQUE
--   Four tables at two grains. order_items is the bridge between orders and
--   sellers, so the seller dimension only becomes reachable through it.
--
--   COUNT(DISTINCT o.order_id) is essential rather than cosmetic: order_items has
--   112,650 rows for 98,666 orders, so COUNT(*) would count multi-item orders
--   several times and quietly distort every rate in the report.
--
--   The delivery date filter is a correctness requirement, not tidiness. Eight
--   orders carry status 'delivered' with a NULL delivery date — contradictory
--   source data. `date > date` is NULL for those rows, so they are neither late
--   nor on time; excluding them explicitly keeps the denominator honest instead
--   of letting NULL semantics silently decide.
-- -----------------------------------------------------------------------------
\echo '=== Q1. Late delivery rate by seller state ==='

WITH order_delivery AS (
    -- One row per order per seller. An order split across two sellers counts
    -- against both, which is correct: either could be the cause of the delay.
    SELECT DISTINCT
        o.order_id,
        oi.seller_id,
        s.seller_state,
        o.order_delivered_customer_date > o.order_estimated_delivery_date
            AS is_late,
        (o.order_delivered_customer_date::date
            - o.order_purchase_timestamp::date) AS days_to_deliver,
        (o.order_delivered_customer_date::date
            - o.order_estimated_delivery_date::date) AS days_vs_promise
    FROM orders      o
    JOIN order_items oi ON oi.order_id  = o.order_id
    JOIN sellers     s  ON s.seller_id  = oi.seller_id
    WHERE o.order_status = 'delivered'
      -- Both dates must exist for the comparison to mean anything.
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    seller_state,
    COUNT(DISTINCT order_id)                              AS orders,
    COUNT(DISTINCT order_id) FILTER (WHERE is_late)       AS late_orders,
    ROUND(100.0 * COUNT(DISTINCT order_id) FILTER (WHERE is_late)
                / COUNT(DISTINCT order_id), 2)            AS pct_late,
    ROUND(AVG(days_to_deliver), 1)                        AS avg_days_to_deliver,
    -- Average lateness among late orders only. Averaging over everything would
    -- mix in early deliveries and understate how bad the failures are.
    ROUND(AVG(days_vs_promise) FILTER (WHERE is_late), 1) AS avg_days_late
FROM order_delivery
GROUP BY seller_state
HAVING COUNT(DISTINCT order_id) >= 300
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
--   one FROM clause produces the CARTESIAN PRODUCT of the two per order: an
--   order with 3 items and 2 payments yields 6 rows, and each item's price is
--   counted twice while each payment is counted three times.
--
--   Nothing errors. Both totals simply come out too high, and they stay
--   plausible enough to survive review.
--
--   The fix is to aggregate each child to one row per order FIRST, then join the
--   aggregates. Each CTE below is at order grain, so the join is 1:1 and no
--   duplication is possible.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q2. Fan-out: naive multi-child join vs pre-aggregated join ==='

WITH naive AS (
    SELECT
        SUM(oi.price)         AS item_revenue,
        SUM(p.payment_value)  AS payment_total,
        COUNT(*)              AS row_count
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
    JOIN items_per_order    i  ON i.order_id  = o.order_id
    -- LEFT JOIN because not every order has a payment row; an inner join here
    -- would silently drop those orders from the item revenue total too.
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
-- Query 3 — The geolocation trap, and how to join it safely
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Does physical distance between seller and customer explain late delivery?
--
-- WHY THIS TECHNIQUE
--   Distance needs coordinates, and coordinates live in `geolocation` — a table
--   with NO primary key, 1,000,163 rows covering 19,015 zip prefixes, and
--   261,831 exact duplicate rows.
--
--   Joining it directly to customers multiplies every customer row by ~53.
--   Measured: revenue goes from 13,221,498 to 2,032,852,521, a 154x
--   overstatement, and the row count goes from 110,197 to 16,842,720. A report
--   built on that is not slightly wrong, it is nonsense — but it runs fine and
--   returns a number.
--
--   The fix is to collapse geolocation to exactly one row per zip prefix before
--   joining. AVG of the coordinates is a reasonable centroid for a postcode
--   area; the point is that the aggregation makes the join 1:1 and therefore safe.
--
--   Distance itself uses the haversine formula rather than a naive Pythagorean
--   difference of degrees, because a degree of longitude is not a fixed distance
--   — it shrinks towards the poles. Brazil spans 33 degrees of latitude, so the
--   error would be substantial and systematically biased by region.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q3. Does distance explain lateness? (geolocation pre-aggregated) ==='

WITH geo AS (
    -- Exactly one row per zip prefix. This is what makes every join below safe.
    SELECT
        geolocation_zip_code_prefix AS zip,
        AVG(geolocation_lat)        AS lat,
        AVG(geolocation_lng)        AS lng
    FROM geolocation
    GROUP BY 1
),
order_distance AS (
    SELECT DISTINCT
        o.order_id,
        o.order_delivered_customer_date > o.order_estimated_delivery_date AS is_late,
        (o.order_delivered_customer_date::date
            - o.order_purchase_timestamp::date) AS days_to_deliver,
        -- Haversine great-circle distance in kilometres. 6371 is the Earth's
        -- mean radius; the formula is standard.
        2 * 6371 * asin(sqrt(
              power(sin(radians(cg.lat - sg.lat) / 2), 2)
            + cos(radians(sg.lat)) * cos(radians(cg.lat))
            * power(sin(radians(cg.lng - sg.lng) / 2), 2)
        )) AS distance_km
    FROM orders      o
    JOIN customers   c  ON c.customer_id = o.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    JOIN sellers     s  ON s.seller_id   = oi.seller_id
    JOIN geo         cg ON cg.zip = c.customer_zip_code_prefix
    JOIN geo         sg ON sg.zip = s.seller_zip_code_prefix
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT
    CASE
        WHEN distance_km <   50 THEN 'a. under 50 km'
        WHEN distance_km <  200 THEN 'b. 50-200 km'
        WHEN distance_km <  500 THEN 'c. 200-500 km'
        WHEN distance_km < 1000 THEN 'd. 500-1000 km'
        ELSE                         'e. over 1000 km'
    END                                             AS distance_band,
    COUNT(DISTINCT order_id)                        AS orders,
    ROUND(AVG(days_to_deliver), 1)                  AS avg_days_to_deliver,
    ROUND(100.0 * COUNT(DISTINCT order_id) FILTER (WHERE is_late)
                / COUNT(DISTINCT order_id), 2)      AS pct_late
FROM order_distance
GROUP BY distance_band
ORDER BY distance_band;


-- -----------------------------------------------------------------------------
-- Query 4 — Does late delivery actually cost us review scores?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Late deliveries are assumed to damage reviews. By how much?
--
-- WHY THIS TECHNIQUE
--   Reviews are a THIRD child of orders, so the same fan-out rule applies:
--   98,673 distinct orders carry 99,224 review rows, meaning some orders were
--   reviewed more than once. Pre-aggregating to one score per order stops those
--   orders being weighted twice.
--
--   LEFT JOIN, not INNER: not every order was reviewed. An inner join would
--   silently restrict the analysis to reviewed orders only — a self-selecting
--   population, and exactly the sort of hidden filter that makes a result
--   confidently wrong. The count of unreviewed orders is reported rather than
--   hidden.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q4. Review scores for on-time vs late deliveries ==='

WITH review_per_order AS (
    -- One row per order. AVG handles the orders carrying multiple reviews.
    SELECT order_id, AVG(review_score::numeric) AS review_score
    FROM order_reviews
    GROUP BY order_id
),
order_outcome AS (
    SELECT
        o.order_id,
        o.order_delivered_customer_date > o.order_estimated_delivery_date AS is_late,
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
        WHEN NOT is_late AND days_vs_promise <= -10 THEN 'a. 10+ days early'
        WHEN NOT is_late                            THEN 'b. on time'
        WHEN days_vs_promise <=  3                  THEN 'c. up to 3 days late'
        WHEN days_vs_promise <= 10                  THEN 'd. 4-10 days late'
        ELSE                                             'e. more than 10 days late'
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
--   This is the operational payoff: five tables joined to produce a list an
--   account manager could act on tomorrow.
--
--   Every child table is pre-aggregated to order grain before being joined, so
--   no measure can be double-counted. The volume threshold exists because a
--   seller with 4 orders and 2 late has a 50% failure rate and no commercial
--   significance — percentages on tiny denominators are the most common way a
--   ranking gets hijacked by noise.
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
        o.order_delivered_customer_date > o.order_estimated_delivery_date AS is_late
    FROM orders      o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND o.order_estimated_delivery_date IS NOT NULL
),
seller_revenue AS (
    -- Revenue is aggregated separately from the order-level lateness flags,
    -- because mixing the two grains in one join would inflate both.
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
