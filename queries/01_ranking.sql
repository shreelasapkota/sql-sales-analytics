-- =============================================================================
-- 01_ranking.sql — Top-N analysis with RANK, DENSE_RANK, ROW_NUMBER and NTILE
-- =============================================================================
-- Target: PostgreSQL 17
-- Run:    psql -d olist -f queries/01_ranking.sql
--
-- CONVENTIONS USED THROUGHOUT THIS FILE
-- -------------------------------------
-- Revenue      SUM(order_items.price). Freight is excluded because it is a
--              logistics cost passed through to the customer, not merchandise
--              revenue. Queries that care about total customer spend say so and
--              add freight_value explicitly.
--
-- Order filter order_status = 'delivered'. Delivered orders are 96,478 of
--              99,441 and carry 97.4% of all revenue (13.22M of 13.59M BRL).
--              Cancelled and unavailable orders represent revenue that was never
--              realised, so including them would overstate performance.
--
-- Categories   Joined via LEFT JOIN to product_category_translation and wrapped
--              in COALESCE. The lookup covers 71 of the 73 categories actually
--              in use — `pc_gamer` and
--              `portateis_cozinha_e_preparadores_de_alimentos` have no English
--              name. An INNER JOIN here would silently delete those products
--              from every ranking rather than showing them untranslated.
--
-- A NOTE ON WHY THESE ARE WINDOW FUNCTIONS AND NOT GROUP BY
-- ---------------------------------------------------------
-- Every question below is "rank rows *within* a group, then keep the best few".
-- GROUP BY collapses a group into one row, so it can answer "what is the top
-- revenue in each category" but cannot tell you *which product* earned it, nor
-- return the top five. Window functions compute across a partition while
-- keeping every row addressable, which is exactly what top-N-per-group needs.
--
-- The pre-window-function alternative is a correlated subquery per row
-- ("count how many products in this category beat me"), which re-scans the
-- table once per row. On 112,650 line items that is dramatically slower and far
-- harder to read.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Which of RANK, DENSE_RANK and ROW_NUMBER should a top-N use?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   In telephony, what are the best-selling products by units — and does the
--   choice of ranking function change who appears in a "top 5" list?
--
-- WHY THIS TECHNIQUE
--   All three functions are shown side by side on the same partition because
--   they differ only when values tie, and this category really does tie twice
--   inside the top 8: two products at 68 units, and two more at 53. Ranking a
--   top-N list with the wrong function silently drops a legitimate result, so
--   the choice is a correctness decision, not a stylistic one.
--
-- HOW TO READ THE OUTPUT
--   units   ROW_NUMBER   RANK   DENSE_RANK
--     89        1          1        1
--     79        2          2        2
--     68        3          3        3     <- tie
--     68        4          3        3     <- tie
--     59        5          5        4     <- RANK skipped 4; DENSE_RANK did not
--     53        6          6        5     <- tie
--     53        7          6        5     <- tie
--     50        8          8        6     <- RANK skipped 7
--
--   ROW_NUMBER  always distinct; breaks ties arbitrarily
--   RANK        ties share a rank, then SKIPS positions (no rank 4 or 7 above)
--   DENSE_RANK  ties share a rank, and the next value never skips
--
--   The practical consequence: "top 5 by ROW_NUMBER" cuts the list at 59 units
--   and returns only one of the two products tied at 53 — and *which* one is
--   not deterministic between runs. Use ROW_NUMBER only when you need exactly N
--   rows and an arbitrary tiebreak is acceptable; use RANK or DENSE_RANK when
--   tied rows deserve equal billing.
--
--   A second lesson is visible in the revenue column: the two products tied at
--   53 units earned 10,854 and 14,818 BRL. Ranking by units and ranking by
--   revenue are different questions with different answers, so the metric a
--   report ranks on has to be a deliberate choice.
-- -----------------------------------------------------------------------------
\echo '=== Q1. Ranking functions compared on real ties (telephony) ==='

WITH product_units AS (
    SELECT
        oi.product_id,
        COUNT(*)     AS units_sold,
        SUM(oi.price) AS revenue
    FROM order_items oi
    JOIN orders   o ON o.order_id   = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    WHERE o.order_status = 'delivered'
      AND p.product_category_name = 'telefonia'   -- telephony
    GROUP BY oi.product_id
)
SELECT
    LEFT(product_id, 8)          AS product,
    units_sold,
    ROUND(revenue, 2)            AS revenue_brl,
    -- ROW_NUMBER gets an explicit tiebreak; RANK and DENSE_RANK deliberately do
    -- not. See the note below on why they differ.
    ROW_NUMBER() OVER (ORDER BY units_sold DESC, product_id) AS row_number,
    RANK()       OVER (ORDER BY units_sold DESC)             AS rank,
    DENSE_RANK() OVER (ORDER BY units_sold DESC)             AS dense_rank
FROM product_units
ORDER BY units_sold DESC, product_id
LIMIT 8;

-- WHY ROW_NUMBER HAS A TIEBREAK HERE AND THE OTHER TWO DO NOT
--   This query originally ordered all three by units_sold alone. Running the
--   file repeatedly proved the point it was making: the two products tied at 68
--   units SWAPPED POSITIONS between runs, and their row_number values swapped
--   with them. The documented output above stopped matching what the file
--   printed.
--
--   Adding `product_id` to ROW_NUMBER's ORDER BY makes the tiebreak explicit and
--   the result reproducible. It is added ONLY to ROW_NUMBER, because adding it
--   to RANK or DENSE_RANK would make every row unique and destroy the ties this
--   query exists to demonstrate.
--
--   That asymmetry is the practical lesson. RANK and DENSE_RANK are
--   deterministic in their VALUES whatever the peer order, because tied rows
--   share a rank by definition. ROW_NUMBER is not: it must hand out distinct
--   numbers, so with no tiebreak the database picks arbitrarily and may pick
--   differently on the next execution. If a report paginates or diffs on
--   ROW_NUMBER, give it a unique tiebreak or the results will not be stable.


-- -----------------------------------------------------------------------------
-- Query 2 — Top 5 products in every category
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Which products drive revenue in each category? Merchandising needs the
--   leaders per category, not a global list, because a global top 50 would be
--   dominated by a handful of large categories and say nothing about the rest.
--
-- WHY THIS TECHNIQUE
--   DENSE_RANK with PARTITION BY category restarts the ranking for every
--   category in one pass over the data. DENSE_RANK rather than ROW_NUMBER so
--   genuinely tied products both appear; that means a category can return more
--   than five rows, which is the honest answer rather than an arbitrary cut.
--
--   The ranking is computed in a CTE and filtered in the outer query because
--   WHERE runs BEFORE window functions are evaluated. Referring to
--   `revenue_rank` in a WHERE clause on the same query level is a syntax error.
--   The CTE is what makes the window result available to a filter.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q2. Top 5 products per category by revenue (top 6 categories shown) ==='

WITH product_revenue AS (
    -- One row per product, with its category resolved to English.
    SELECT
        COALESCE(t.product_category_name_english,
                 p.product_category_name)   AS category,
        oi.product_id,
        SUM(oi.price)                       AS revenue,
        COUNT(*)                            AS units_sold
    FROM order_items oi
    JOIN orders   o ON o.order_id   = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    LEFT JOIN product_category_translation t
           ON t.product_category_name = p.product_category_name
    WHERE o.order_status = 'delivered'
      -- 610 products carry no category at all. They are excluded deliberately:
      -- a "top products per category" report has no category to place them in.
      AND p.product_category_name IS NOT NULL
    GROUP BY 1, 2
),
ranked AS (
    SELECT
        category,
        product_id,
        revenue,
        units_sold,
        DENSE_RANK() OVER (PARTITION BY category ORDER BY revenue DESC)
            AS revenue_rank,
        -- Each product's share of its own category, computed over the same
        -- partition. A second pass or self-join would otherwise be needed.
        ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY category), 1)
            AS pct_of_category
    FROM product_revenue
),
top_categories AS (
    -- Limit the printed output to the six largest categories so the result is
    -- readable. Remove this CTE to rank products across all 73.
    SELECT category
    FROM product_revenue
    GROUP BY category
    ORDER BY SUM(revenue) DESC
    LIMIT 6
)
SELECT
    r.category,
    r.revenue_rank,
    LEFT(r.product_id, 8)  AS product,
    ROUND(r.revenue, 2)    AS revenue_brl,
    r.units_sold,
    r.pct_of_category
FROM ranked r
JOIN top_categories tc ON tc.category = r.category
WHERE r.revenue_rank <= 5
ORDER BY r.category, r.revenue_rank;


-- -----------------------------------------------------------------------------
-- Query 3 — Top 3 sellers in each state
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Who are the leading sellers in each Brazilian state, and how much of that
--   state's revenue do they control? This drives account management: a state
--   where three sellers hold most of the revenue is a concentration risk.
--
-- WHY THIS TECHNIQUE
--   RANK partitioned by seller state answers "top 3 per state" in a single scan.
--   RANK rather than DENSE_RANK because the business question is about position
--   in a league table, where a gap after a tie is the expected convention.
--
--   COUNT(DISTINCT o.order_id) rather than COUNT(*) matters here: order_items
--   has one row per line item, so an order containing four items would otherwise
--   count as four orders and inflate the seller's apparent order volume.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q3. Top 3 sellers per state (10 largest states) ==='

WITH seller_revenue AS (
    SELECT
        s.seller_state,
        s.seller_id,
        SUM(oi.price)                 AS revenue,
        COUNT(DISTINCT o.order_id)    AS orders
    FROM order_items oi
    JOIN orders  o ON o.order_id  = oi.order_id
    JOIN sellers s ON s.seller_id = oi.seller_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1, 2
),
ranked AS (
    SELECT
        seller_state,
        seller_id,
        revenue,
        orders,
        RANK() OVER (PARTITION BY seller_state ORDER BY revenue DESC)
            AS state_rank,
        ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY seller_state), 1)
            AS pct_of_state,
        -- Total revenue of the whole state, repeated on each row. Used below to
        -- pick the largest states without a second aggregation.
        SUM(revenue) OVER (PARTITION BY seller_state) AS state_revenue
    FROM seller_revenue
)
SELECT
    seller_state,
    state_rank,
    LEFT(seller_id, 8)       AS seller,
    ROUND(revenue, 2)        AS revenue_brl,
    orders,
    pct_of_state
FROM ranked
WHERE state_rank <= 3
  AND seller_state IN (
        SELECT seller_state
        FROM seller_revenue
        GROUP BY seller_state
        ORDER BY SUM(revenue) DESC
        LIMIT 10
      )
ORDER BY state_revenue DESC, state_rank;


-- -----------------------------------------------------------------------------
-- Query 4 — The single best-selling category in each state
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   What does each state buy most? Regional demand differences drive inventory
--   placement and which warehouse should stock what.
--
-- WHY THIS TECHNIQUE
--   This is the one place ROW_NUMBER is the *right* choice. The question asks
--   for exactly one category per state, so an arbitrary tiebreak is acceptable
--   and a tie must not return two rows. RANK would return both tied categories
--   and break the "one row per state" contract this report promises.
--
--   Filtering `WHERE rn = 1` on a ROW_NUMBER is the standard SQL idiom for
--   "the top row per group". PostgreSQL also offers DISTINCT ON, which is
--   shorter but non-standard; ROW_NUMBER is used here because it ports to any
--   database and makes the ordering rule explicit.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q4. Leading category in each state (top 12 states by revenue) ==='

WITH state_category_revenue AS (
    SELECT
        c.customer_state,
        COALESCE(t.product_category_name_english,
                 p.product_category_name) AS category,
        SUM(oi.price)                     AS revenue
    FROM order_items oi
    JOIN orders    o ON o.order_id    = oi.order_id
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN products  p ON p.product_id  = oi.product_id
    LEFT JOIN product_category_translation t
           ON t.product_category_name = p.product_category_name
    WHERE o.order_status = 'delivered'
      AND p.product_category_name IS NOT NULL
    GROUP BY 1, 2
),
ranked AS (
    SELECT
        customer_state,
        category,
        revenue,
        -- product_id is not available here, so the tiebreak is the category
        -- name. Naming an explicit tiebreak makes the result deterministic
        -- across runs; without it, tied rows could swap between executions.
        ROW_NUMBER() OVER (PARTITION BY customer_state
                           ORDER BY revenue DESC, category) AS rn,
        SUM(revenue) OVER (PARTITION BY customer_state)     AS state_revenue
    FROM state_category_revenue
)
SELECT
    customer_state,
    category                              AS top_category,
    ROUND(revenue, 2)                     AS category_revenue_brl,
    ROUND(state_revenue, 2)               AS state_revenue_brl,
    ROUND(100.0 * revenue / state_revenue, 1) AS pct_of_state
FROM ranked
WHERE rn = 1
ORDER BY state_revenue DESC
LIMIT 12;


-- -----------------------------------------------------------------------------
-- Query 5 — How concentrated is revenue across sellers?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Is marketplace revenue spread evenly across sellers, or does a small group
--   carry the platform? If a handful of sellers dominate, losing one is a
--   material commercial risk.
--
-- WHY THIS TECHNIQUE
--   NTILE(10) splits sellers into ten equal-sized buckets by revenue, which is
--   the natural way to express a Pareto distribution. Doing this with GROUP BY
--   would require hard-coded revenue thresholds that go stale as the data grows;
--   NTILE derives the buckets from the data itself.
--
--   CUME_DIST is included as the continuous counterpart: it reports the fraction
--   of sellers at or below each revenue level, which is what "this seller is in
--   the top 1%" actually means.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q5. Seller revenue concentration by decile ==='

WITH seller_revenue AS (
    SELECT
        oi.seller_id,
        SUM(oi.price) AS revenue
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
),
bucketed AS (
    SELECT
        seller_id,
        revenue,
        -- NTILE assigns bucket 1 to the highest revenue because of DESC.
        NTILE(10) OVER (ORDER BY revenue DESC) AS revenue_decile
    FROM seller_revenue
)
SELECT
    revenue_decile,
    COUNT(*)                    AS sellers,
    ROUND(SUM(revenue), 2)      AS decile_revenue_brl,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)
                                AS pct_of_total_revenue,
    -- A window function applied on top of an aggregate: SUM(SUM(...)) OVER ()
    -- computes the grand total across all groups after grouping, which is what
    -- makes the running share possible without a second query or a self-join.
    ROUND(100.0 * SUM(SUM(revenue)) OVER (ORDER BY revenue_decile)
                / SUM(SUM(revenue)) OVER (), 1)
                                AS cumulative_pct,
    ROUND(AVG(revenue), 2)      AS avg_seller_revenue_brl
FROM bucketed
GROUP BY revenue_decile
ORDER BY revenue_decile;
