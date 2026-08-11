-- =============================================================================
-- 03_partition_calculations.sql — Running totals and cumulative sums
-- =============================================================================
-- Target: PostgreSQL 17
-- Run:    psql -d olist -f queries/03_partition_calculations.sql
--
-- Conventions from 01_ranking.sql carry over: revenue is SUM(order_items.price),
-- and only delivered orders count.
--
-- THE ONE THING TO UNDERSTAND BEFORE READING THIS FILE
-- ----------------------------------------------------
-- Writing `SUM(x) OVER (ORDER BY d)` does NOT give you a running total. It gives
-- you a running total *only when d has no duplicates*. Omitting the frame
-- silently selects the SQL default:
--
--     RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--
-- RANGE operates on VALUES, so "current row" means every row sharing the current
-- row's ORDER BY value — all its peers. With duplicate dates, every tied row
-- receives the same total, and the running total flattens into a plateau.
--
-- What people almost always mean is:
--
--     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--
-- Q1 demonstrates the difference on a real customer. Every subsequent query in
-- this file states its frame explicitly, because relying on the default is how
-- this bug reaches production.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — The default window frame silently breaks running totals
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Show a customer's spending accumulating across their order history.
--
-- WHY THIS TECHNIQUE
--   Customer 12f5d6e1 placed six delivered orders on a single day, 2017-01-05.
--   Ordering by date alone therefore produces six tied rows, which is exactly
--   the condition that exposes the default frame.
--
--   The two columns below differ only in that one omits the frame:
--     default_frame_range  SUM(rev) OVER (ORDER BY d)
--     explicit_rows        SUM(rev) OVER (ORDER BY d ROWS UNBOUNDED PRECEDING)
--
-- HOW TO READ THE OUTPUT
--   default_frame_range returns 58.40 on ALL SIX ROWS. Every row is a peer of
--   every other, so each one sums the entire day. The running total does not run.
--
--   explicit_rows returns 9.90, 16.80, 26.70, 36.60, 47.50, 58.40 — the actual
--   accumulation.
--
--   Both are "correct" per the standard; only one answers the question. Note
--   that they agree on the FINAL row, which is what makes this so easy to miss:
--   a spot-check of the last value passes, and only the intermediate rows lie.
--
--   The deeper fix is a deterministic ORDER BY. Adding order_id as a tiebreak
--   removes the ties entirely, so RANGE and ROWS converge. Ordering by something
--   unique is the real defence; the explicit frame is the safety net.
-- -----------------------------------------------------------------------------
\echo '=== Q1. Default RANGE frame vs explicit ROWS on tied dates ==='

WITH customer_orders AS (
    SELECT
        o.order_id,
        o.order_purchase_timestamp::date AS order_date,
        SUM(oi.price)                    AS order_revenue
    FROM customers   c
    JOIN orders      o  ON o.customer_id = c.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    WHERE c.customer_unique_id = '12f5d6e1cbf93dafd9dcc19095df0b3d'
      AND o.order_status = 'delivered'
    GROUP BY 1, 2
)
SELECT
    LEFT(order_id, 8)     AS order_ref,
    order_date,
    ROUND(order_revenue, 2) AS order_brl,
    -- No frame given: defaults to RANGE, which lumps all six tied rows together.
    ROUND(SUM(order_revenue) OVER (ORDER BY order_date), 2)
        AS default_frame_range,
    -- Explicit ROWS: a genuine row-by-row accumulation.
    ROUND(SUM(order_revenue) OVER (ORDER BY order_date
              ROWS UNBOUNDED PRECEDING), 2)
        AS explicit_rows,
    -- Deterministic ORDER BY: no ties left, so the frame no longer matters.
    ROUND(SUM(order_revenue) OVER (ORDER BY order_date, order_id), 2)
        AS unique_order_by
FROM customer_orders
ORDER BY order_date, order_id;


-- -----------------------------------------------------------------------------
-- Query 2 — How does a repeat customer's spending accumulate?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   For customers who ordered more than once, how does their cumulative spend
--   build up, and how long do they wait between orders?
--
-- WHY THIS TECHNIQUE
--   PARTITION BY customer_unique_id restarts the accumulation for each person,
--   so one pass produces every customer's independent running total. Without the
--   partition, the total would spill from one customer into the next.
--
--   customer_unique_id, NOT customer_id, is the partition key. Olist issues a
--   fresh customer_id per order, so partitioning by customer_id would give every
--   partition exactly one row and every "running total" would equal that single
--   order. This is the single easiest way to get this dataset wrong.
--
--   Repeat buyers are rare here: 90,557 of 93,358 people (97.0%) ordered exactly
--   once, counting delivered orders only.
--   The filter keeps the output meaningful, since a running total over one row
--   demonstrates nothing.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q2. Cumulative spend for the most frequent repeat customers ==='

WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        o.order_purchase_timestamp AS ordered_at,
        SUM(oi.price)              AS order_revenue
    FROM customers   c
    JOIN orders      o  ON o.customer_id = c.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1, 2, 3
),
repeat_customers AS (
    SELECT customer_unique_id
    FROM customer_orders
    GROUP BY customer_unique_id
    HAVING COUNT(*) >= 5
),
sequenced AS (
    SELECT
        co.customer_unique_id,
        co.ordered_at,
        co.order_revenue,
        ROW_NUMBER() OVER w                         AS order_seq,
        -- `OVER (w ROWS ...)` reuses the named window's PARTITION BY and
        -- ORDER BY while adding a frame, so the spec is written once. Repeating
        -- it inline invites the two copies to drift apart during edits.
        SUM(co.order_revenue) OVER (w ROWS UNBOUNDED PRECEDING)
                                                    AS cumulative_brl,
        -- Days since this customer's previous order. LAG is confined to the
        -- partition, so the first order of each customer correctly yields NULL
        -- rather than reaching into another customer's history.
        co.ordered_at::date
            - LAG(co.ordered_at::date) OVER w       AS days_since_prev,
        -- Each order's share of everything that customer ever spent. The frame
        -- is deliberately unbounded in BOTH directions so the denominator is the
        -- partition total, not the running total.
        ROUND(100.0 * co.order_revenue
              / SUM(co.order_revenue) OVER (PARTITION BY co.customer_unique_id), 1)
                                                    AS pct_of_lifetime
    FROM customer_orders co
    JOIN repeat_customers rc USING (customer_unique_id)
    WINDOW w AS (PARTITION BY co.customer_unique_id
                 ORDER BY co.ordered_at, co.order_id)
)
SELECT
    LEFT(customer_unique_id, 8) AS customer,
    order_seq,
    ordered_at::date            AS order_date,
    ROUND(order_revenue, 2)     AS order_brl,
    ROUND(cumulative_brl, 2)    AS cumulative_brl,
    days_since_prev,
    pct_of_lifetime
FROM sequenced
-- ORDER BY inside the subquery matters: a bare LIMIT has no defined ordering,
-- so PostgreSQL may return different customers between runs and the output
-- would not be reproducible.
WHERE customer_unique_id IN (
        SELECT customer_unique_id
        FROM repeat_customers
        ORDER BY customer_unique_id
        LIMIT 3
      )
ORDER BY customer_unique_id, order_seq;


-- -----------------------------------------------------------------------------
-- Query 3 — Cumulative revenue by month within each state
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   How did each state's revenue accumulate through 2018, and what share of its
--   full-year total had it reached by each month?
--
-- WHY THIS TECHNIQUE
--   Two window functions over the same partition, with different frames, answer
--   both halves in one pass:
--     SUM(...) OVER (PARTITION BY state ORDER BY month ROWS UNBOUNDED PRECEDING)
--         accumulates month by month
--     SUM(...) OVER (PARTITION BY state)
--         with no ORDER BY, covers the whole partition and gives the denominator
--
--   Omitting ORDER BY is what makes the second one a partition-wide total. Adding
--   an ORDER BY would silently turn it back into a running total and the
--   percentage would be 100% on every row — a quietly wrong result that looks
--   plausible.
--
--   A GROUP BY equivalent would need a self-join back onto the same aggregate to
--   attach the state total, scanning twice.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q3. Cumulative 2018 revenue by state (6 largest states) ==='

WITH state_month AS (
    SELECT
        c.customer_state,
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue
    FROM order_items oi
    JOIN orders    o ON o.order_id    = oi.order_id
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      -- 2018-01 to 2018-08, the complete months of 2018 (see 02_trend_analysis
      -- for why September and October are excluded as right-censored).
      AND o.order_purchase_timestamp >= '2018-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
    GROUP BY 1, 2
),
accumulated AS (
    SELECT
        customer_state,
        month,
        revenue,
        SUM(revenue) OVER (PARTITION BY customer_state
                           ORDER BY month
                           ROWS UNBOUNDED PRECEDING) AS cumulative_revenue,
        -- No ORDER BY: the whole partition, i.e. the state's 8-month total.
        SUM(revenue) OVER (PARTITION BY customer_state) AS state_total
    FROM state_month
)
SELECT
    customer_state,
    to_char(month, 'YYYY-MM')          AS month,
    ROUND(revenue, 2)                  AS month_brl,
    ROUND(cumulative_revenue, 2)       AS cumulative_brl,
    ROUND(100.0 * cumulative_revenue / state_total, 1) AS pct_of_state_total
FROM accumulated
WHERE customer_state IN ('SP', 'RJ', 'MG', 'RS', 'PR', 'SC')
ORDER BY customer_state, month;


-- -----------------------------------------------------------------------------
-- Query 4 — How many sellers make up 80% of revenue?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Concentration was measured by decile in 01_ranking.sql. The sharper
--   commercial question is the exact count: how few sellers reach 50% and 80%
--   of marketplace revenue?
--
-- WHY THIS TECHNIQUE
--   A running total over sellers sorted by revenue descending gives a Pareto
--   curve directly. Each row carries the cumulative share up to and including
--   that seller, so the answer is read off the curve rather than computed by
--   guessing thresholds.
--
--   ROW_NUMBER supplies the seller count at each point. The ORDER BY includes
--   seller_id as a tiebreak so the accumulation is deterministic — without it,
--   sellers on identical revenue could reorder between runs and shift the
--   reported counts.
--
--   Reporting only the crossing points keeps the output to a few rows instead of
--   2,970, and the filter sits in an outer query because the window results it
--   tests do not exist until the CTE has been evaluated.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q4. Pareto: sellers required to reach each revenue threshold ==='

WITH seller_revenue AS (
    SELECT
        oi.seller_id,
        SUM(oi.price) AS revenue
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
),
pareto AS (
    SELECT
        seller_id,
        revenue,
        ROW_NUMBER() OVER (ORDER BY revenue DESC, seller_id) AS seller_rank,
        ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC, seller_id
                                         ROWS UNBOUNDED PRECEDING)
                    / SUM(revenue) OVER (), 3)               AS cumulative_pct,
        COUNT(*) OVER ()                                     AS total_sellers
    FROM seller_revenue
),
thresholds AS (
    SELECT
        p.*,
        -- Flag the first row to cross each threshold by comparing against the
        -- previous row's cumulative share.
        --
        -- COALESCE(..., 0) is load-bearing. The first row has no predecessor, so
        -- LAG returns NULL, and `NULL < 25` evaluates to NULL rather than true —
        -- meaning the row would NOT be selected. On this data the top seller
        -- holds only 1.7% so no threshold is crossed at row 1 and the bug stays
        -- invisible, but on a more concentrated marketplace the 25% row would
        -- silently vanish from the report. Treating "no previous row" as 0%
        -- makes the comparison correct at the boundary.
        COALESCE(LAG(cumulative_pct) OVER (ORDER BY seller_rank), 0) AS prev_pct
    FROM pareto p
)
SELECT
    seller_rank                                   AS sellers_needed,
    ROUND(100.0 * seller_rank / total_sellers, 1) AS pct_of_all_sellers,
    ROUND(revenue, 2)                             AS this_seller_brl,
    cumulative_pct                                AS cumulative_revenue_pct
FROM thresholds
WHERE (cumulative_pct >= 25 AND prev_pct < 25)
   OR (cumulative_pct >= 50 AND prev_pct < 50)
   OR (cumulative_pct >= 80 AND prev_pct < 80)
   OR (cumulative_pct >= 90 AND prev_pct < 90)
   OR (cumulative_pct >= 99 AND prev_pct < 99)
ORDER BY seller_rank;


-- -----------------------------------------------------------------------------
-- Query 5 — FIRST_VALUE and LAST_VALUE, and why LAST_VALUE usually lies
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   For each state, compare its best and worst month of 2018 against each
--   month's actual revenue.
--
-- WHY THIS TECHNIQUE
--   This is the frame problem from Q1 wearing a different hat, and it catches
--   people far more often because the output looks reasonable.
--
--   LAST_VALUE(x) OVER (PARTITION BY s ORDER BY x) inherits the default frame,
--   UNBOUNDED PRECEDING TO CURRENT ROW. The frame ends at the current row, so
--   "the last value" is whatever the current row holds. It returns the current
--   row's own value on every row — an expensive way to write x.
--
--   FIRST_VALUE happens to work with the default frame, because the frame's
--   start is genuinely the partition start. That asymmetry is precisely why the
--   bug is so easy to miss: half the query is right.
--
--   The fix is to state the full frame: ROWS BETWEEN UNBOUNDED PRECEDING AND
--   UNBOUNDED FOLLOWING. The broken version is kept alongside for comparison.
--
--   MIN and MAX as plain window aggregates are shown too, and are the better
--   choice in real code: they need no frame reasoning and cannot be got wrong.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q5. LAST_VALUE with the default frame vs a correct full frame ==='

WITH state_month AS (
    SELECT
        c.customer_state,
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue
    FROM order_items oi
    JOIN orders    o ON o.order_id    = oi.order_id
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2018-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
      AND c.customer_state IN ('SP', 'RJ', 'MG')
    GROUP BY 1, 2
)
SELECT
    customer_state,
    to_char(month, 'YYYY-MM') AS month,
    ROUND(revenue, 2)         AS month_brl,
    -- Correct with the default frame: the frame starts at the partition start.
    ROUND(FIRST_VALUE(revenue) OVER (PARTITION BY customer_state
                                     ORDER BY revenue DESC), 2)
        AS best_month_brl,
    -- BROKEN: default frame ends at the current row, so this just echoes
    -- month_brl. Kept deliberately to make the failure visible.
    ROUND(LAST_VALUE(revenue) OVER (PARTITION BY customer_state
                                    ORDER BY revenue DESC), 2)
        AS worst_month_broken,
    -- Correct: the frame is stated in full.
    ROUND(LAST_VALUE(revenue) OVER (PARTITION BY customer_state
                                    ORDER BY revenue DESC
                                    ROWS BETWEEN UNBOUNDED PRECEDING
                                             AND UNBOUNDED FOLLOWING), 2)
        AS worst_month_fixed,
    -- Simplest and safest: no frame reasoning required at all.
    ROUND(MIN(revenue) OVER (PARTITION BY customer_state), 2)
        AS worst_month_via_min
FROM state_month
ORDER BY customer_state, revenue DESC;
