-- =============================================================================
-- 04_ctes.sql — Common table expressions, recursive and non-recursive
-- =============================================================================
-- Target: PostgreSQL 17
-- Run:    psql -d olist -f queries/04_ctes.sql
--
-- Conventions from 01_ranking.sql carry over: revenue is SUM(order_items.price),
-- and only delivered orders count.
--
-- WHAT A CTE IS ACTUALLY FOR
-- --------------------------
-- A non-recursive CTE is a named subquery. It buys readability, not speed. Since
-- PostgreSQL 12 a plain CTE is normally INLINED into the surrounding query, so
-- it optimises exactly like a subquery would — it is not a temporary table and
-- it is not automatically materialised.
--
-- That matters in both directions:
--   * A CTE referenced ONCE costs nothing. Use them freely for clarity.
--   * A CTE referenced MANY times may be re-computed each time. If the CTE is
--     expensive, MATERIALIZED forces it to run once.
--
-- Before PostgreSQL 12, CTEs were always materialised — an "optimisation fence"
-- that people exploited deliberately. Code written against that assumption can
-- change behaviour on upgrade. Interviewers like this question because it
-- separates people who have read the release notes from people who have not.
--
-- A recursive CTE is a genuinely different tool: it is the only way in standard
-- SQL to walk a hierarchy of unknown depth. Q3 uses one, and states plainly
-- where a simpler construct would have done the job.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Customer lifetime value
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   What is a customer actually worth over their whole relationship with us, and
--   how much of total revenue comes from people who came back?
--
-- WHY THIS TECHNIQUE
--   The calculation has three distinct stages — resolve orders to people, roll
--   those up per person, then summarise the population. Layered CTEs give each
--   stage a name, so the query reads top to bottom in the order you would
--   explain it aloud. Written as nested subqueries it would be three levels deep
--   and read inside-out.
--
--   Each CTE here is referenced once, so PostgreSQL inlines them and there is no
--   performance cost to the extra clarity.
--
-- THE TRAP THAT DEFINES THIS QUERY
--   Olist issues a NEW customer_id for every single order. There are 99,441
--   customer_id values and 99,441 orders — one apiece.
--
--   Group by customer_id and every customer appears to have ordered exactly
--   once. Lifetime value collapses to average order value, repeat rate reads as
--   0%, and the number looks completely plausible. customer_unique_id is the
--   actual person: 93,358 of them placed delivered orders.
--
--   Both columns are shown side by side below so the difference is measured
--   rather than asserted.
-- -----------------------------------------------------------------------------
\echo '=== Q1. Customer lifetime value, and the customer_id trap ==='

WITH order_revenue AS (
    -- Stage 1: collapse line items to one row per order, and attach the person.
    -- Aggregating here rather than later keeps the grain unambiguous: joining
    -- orders straight to order_items would multiply each order by its item count.
    SELECT
        c.customer_unique_id,
        c.customer_id,
        o.order_id,
        o.order_purchase_timestamp,
        SUM(oi.price) AS order_revenue
    FROM customers   c
    JOIN orders      o  ON o.customer_id = c.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1, 2, 3, 4
),
per_person AS (
    -- Stage 2: one row per actual human being.
    SELECT
        customer_unique_id,
        COUNT(*)                          AS orders,
        SUM(order_revenue)                AS lifetime_value,
        MIN(order_purchase_timestamp)::date AS first_order,
        MAX(order_purchase_timestamp)::date AS last_order
    FROM order_revenue
    GROUP BY customer_unique_id
),
per_customer_id AS (
    -- Stage 2b: the same thing done WRONG, for comparison.
    SELECT
        customer_id,
        COUNT(*)           AS orders,
        SUM(order_revenue) AS lifetime_value
    FROM order_revenue
    GROUP BY customer_id
)
SELECT
    'grouped by customer_unique_id (correct)' AS method,
    COUNT(*)                                  AS distinct_customers,
    ROUND(AVG(lifetime_value), 2)             AS avg_ltv_brl,
    ROUND(MAX(lifetime_value), 2)             AS max_ltv_brl,
    ROUND(AVG(orders), 3)                     AS avg_orders_per_customer,
    ROUND(100.0 * COUNT(*) FILTER (WHERE orders > 1) / COUNT(*), 2) AS pct_repeat_buyers
FROM per_person
UNION ALL
SELECT
    'grouped by customer_id (wrong)',
    COUNT(*),
    ROUND(AVG(lifetime_value), 2),
    ROUND(MAX(lifetime_value), 2),
    ROUND(AVG(orders), 3),
    ROUND(100.0 * COUNT(*) FILTER (WHERE orders > 1) / COUNT(*), 2)
FROM per_customer_id;


-- -----------------------------------------------------------------------------
-- Query 2 — Segmenting customers by value
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   How is customer value distributed, and is retention spend justified?
--
-- WHY THIS TECHNIQUE
--   The same CTE chain as Q1 feeds a segmentation, which is the practical
--   argument for CTEs: the stages are reusable building blocks rather than a
--   monolithic query.
--
--   NTILE is deliberately NOT used here. Quintiles would force five equal-sized
--   buckets and hide the real shape of this distribution, where the overwhelming
--   majority sit in one group. Explicit value bands describe the population
--   honestly, even though the buckets come out wildly uneven — which is itself
--   the finding.
--
--   NOTE ON MATERIALIZED, AND WHY IT IS *NOT* USED HERE
--   An earlier version of this query marked the first CTE AS MATERIALIZED,
--   justified by a comment saying it was "referenced twice". It is not — each
--   CTE below is referenced exactly once, in a straight chain:
--       order_revenue -> per_person -> segmented -> final SELECT
--
--   With a single reference, MATERIALIZED can only hurt: it forces PostgreSQL to
--   build the full intermediate result instead of inlining the CTE and pushing
--   predicates down into it. The hint was removed.
--
--   MATERIALIZED earns its place when an EXPENSIVE CTE is referenced MORE THAN
--   ONCE, since the inlined form may recompute it per reference. That is a real
--   pattern, just not this query's. Adding optimizer hints on the strength of a
--   plausible-sounding reason rather than a plan is how queries get slower.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q2. Customer value segments ==='

WITH order_revenue AS (
    SELECT
        c.customer_unique_id,
        o.order_id,
        SUM(oi.price) AS order_revenue
    FROM customers   c
    JOIN orders      o  ON o.customer_id = c.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1, 2
),
per_person AS (
    SELECT
        customer_unique_id,
        COUNT(*)           AS orders,
        SUM(order_revenue) AS lifetime_value
    FROM order_revenue
    GROUP BY customer_unique_id
),
segmented AS (
    SELECT
        customer_unique_id,
        orders,
        lifetime_value,
        CASE
            WHEN orders > 1 AND lifetime_value >= 500 THEN '1. repeat, high value'
            WHEN orders > 1                           THEN '2. repeat, standard'
            WHEN lifetime_value >= 500                THEN '3. one-off, high value'
            WHEN lifetime_value >= 100                THEN '4. one-off, standard'
            ELSE                                           '5. one-off, low value'
        END AS segment
    FROM per_person
)
SELECT
    segment,
    COUNT(*)                                                    AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS pct_of_customers,
    ROUND(SUM(lifetime_value), 2)                               AS segment_revenue_brl,
    ROUND(100.0 * SUM(lifetime_value)
                / SUM(SUM(lifetime_value)) OVER (), 2)          AS pct_of_revenue,
    ROUND(AVG(lifetime_value), 2)                               AS avg_ltv_brl
FROM segmented
GROUP BY segment
ORDER BY segment;


-- -----------------------------------------------------------------------------
-- Query 3 — Recursive CTE: rolling revenue up a geographic hierarchy
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Brazilian postcodes are hierarchical: the leading digits narrow from a broad
--   region down to a neighbourhood. How does revenue aggregate at each level of
--   that hierarchy, so a regional manager can drill from region to district?
--
-- WHY A RECURSIVE CTE
--   The hierarchy is a prefix tree. A 5-digit prefix like 01001 sits under 0100,
--   which sits under 010, under 01, under 0. Each level is the parent of the
--   next, and the tree is built by walking down one digit at a time — a node's
--   children cannot be known without first knowing the node.
--
--   That parent-child descent is what WITH RECURSIVE exists for. The anchor term
--   seeds the top level, and the recursive term repeatedly extends every known
--   node by one more digit until depth 5.
--
-- HONEST ASSESSMENT: IS RECURSION THE RIGHT TOOL HERE?
--   Partly. This hierarchy has a FIXED depth of five, and for a fixed depth
--   GROUPING SETS or ROLLUP would be simpler, faster, and easier to read:
--
--       GROUP BY GROUPING SETS (
--           (LEFT(zip,1)), (LEFT(zip,2)), (LEFT(zip,3)),
--           (LEFT(zip,4)), (zip)
--       )
--
--   Recursion genuinely earns its place when depth is UNKNOWN or VARIABLE — an
--   org chart, a bill of materials, a threaded comment tree — because those
--   cannot be written as a fixed list of grouping sets at all.
--
--   It is worth being able to say this out loud. Reaching for recursion when a
--   simpler construct fits is a common way to make a query harder to maintain
--   than it needs to be. It is used here because the file must demonstrate the
--   technique, and because the same shape genuinely applies to variable-depth
--   trees.
--
-- TWO POSTGRESQL CONSTRAINTS THAT SHAPE THIS QUERY
--   1. The recursive term may not contain aggregates, GROUP BY or DISTINCT. So
--      recursion builds the NODE LIST only, and revenue is aggregated afterwards
--      in the final SELECT.
--   2. UNION is used rather than UNION ALL. UNION deduplicates, which collapses
--      the many leaf zips sharing a prefix into one node per level. With
--      UNION ALL the tree would carry one duplicate row per contributing leaf
--      and grow enormously.
--
--   The recursion is also bounded by `WHERE depth < 5`. A recursive CTE with no
--   terminating condition runs until it exhausts memory; on a cyclic graph that
--   is guaranteed. Always bound the depth.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q3. Recursive rollup of revenue through the zip-prefix hierarchy ==='

WITH RECURSIVE zip_leaf AS (
    -- Leaf level: revenue per full 5-digit prefix. Computed once, then reused by
    -- both the recursion and the final aggregation.
    SELECT
        c.customer_zip_code_prefix AS zip,
        c.customer_state           AS state,
        SUM(oi.price)              AS revenue,
        COUNT(DISTINCT o.order_id) AS orders
    FROM customers   c
    JOIN orders      o  ON o.customer_id = c.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1, 2
),
tree AS (
    -- ANCHOR: the ten top-level regions, one per leading digit.
    SELECT
        LEFT(zip, 1) AS node,
        1            AS depth
    FROM zip_leaf

    UNION

    -- RECURSIVE TERM: extend every known node by one more digit. Each pass
    -- descends exactly one level, so the tree is built breadth-first.
    SELECT
        LEFT(z.zip, t.depth + 1),
        t.depth + 1
    FROM tree     t
    JOIN zip_leaf z ON LEFT(z.zip, t.depth) = t.node
    WHERE t.depth < 5   -- terminating condition; without it this never halts
),
rolled_up AS (
    -- Attach revenue to every node by matching each leaf to the ancestors that
    -- prefix it. A leaf contributes to all five of its ancestors, which is
    -- exactly what a hierarchical rollup means.
    SELECT
        t.depth,
        t.node,
        SUM(z.revenue)      AS revenue,
        SUM(z.orders)       AS orders,
        COUNT(DISTINCT z.zip) AS leaf_zips,
        MIN(z.state)        AS state
    FROM tree     t
    JOIN zip_leaf z ON LEFT(z.zip, t.depth) = t.node
    GROUP BY t.depth, t.node
),
national AS (
    -- The national total must be computed from the LEAF data, independently of
    -- whatever the final WHERE clause keeps.
    --
    -- An earlier version used `SUM(revenue) FILTER (WHERE depth = 1) OVER ()`
    -- in the final SELECT. A window function sees only the rows that survived
    -- WHERE, and the filter below keeps exactly one depth-1 node, so the
    -- "national total" silently became that single node's revenue and every
    -- percentage was inflated. Node 0 reported 100.00% of the nation when its
    -- true share is 21.29%.
    SELECT SUM(revenue) AS total_revenue FROM zip_leaf
)
SELECT
    r.depth,
    r.node                     AS zip_prefix,
    r.state                    AS example_state,
    r.leaf_zips,
    r.orders,
    ROUND(r.revenue, 2)        AS revenue_brl,
    ROUND(100.0 * r.revenue / n.total_revenue, 2) AS pct_of_national
FROM rolled_up r
CROSS JOIN national n
-- Follow ONE branch from the root down to depth 4, so the parent-child
-- relationship is visible and verifiable: 0 -> 01 -> 011 -> 0110..0115.
--
-- Depth 5 is deliberately excluded from this display. An earlier version
-- included it under a LIMIT 25, which truncated the leaf set mid-level — the
-- visible children then summed to less than their parent and the rollup looked
-- broken when it was merely cut off. Showing complete levels is the difference
-- between a demonstration and a misleading one.
--
-- Read it as: the depth-4 rows sum to node 011, which is one of the children
-- summing to 01, which is one of the children summing to 0. Q4 asserts the same
-- property across the whole tree rather than one branch.
WHERE r.node IN ('0', '01', '011')
   OR (r.depth = 4 AND r.node LIKE '011%')
ORDER BY r.depth, r.revenue DESC;


-- -----------------------------------------------------------------------------
-- Query 4 — Verifying the rollup actually balances
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Does every level of the hierarchy sum to the same national total?
--
-- WHY THIS TECHNIQUE
--   A hierarchical rollup that does not balance is silently wrong, and a
--   partially-wrong total is far more damaging than an obviously broken one.
--   Every depth aggregates the SAME leaf revenue through a different grouping,
--   so all five totals must be identical.
--
--   This is a correctness assertion expressed as a query, and it is the kind of
--   check worth writing whenever the join condition is anything cleverer than
--   equality — here `LEFT(z.zip, t.depth) = t.node`, which is easy to get subtly
--   wrong and hard to eyeball.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q4. Rollup balance check: every depth must total the same ==='

WITH RECURSIVE zip_leaf AS (
    SELECT
        c.customer_zip_code_prefix AS zip,
        SUM(oi.price)              AS revenue
    FROM customers   c
    JOIN orders      o  ON o.customer_id = c.customer_id
    JOIN order_items oi ON oi.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
),
tree AS (
    SELECT LEFT(zip, 1) AS node, 1 AS depth FROM zip_leaf
    UNION
    SELECT LEFT(z.zip, t.depth + 1), t.depth + 1
    FROM tree t
    JOIN zip_leaf z ON LEFT(z.zip, t.depth) = t.node
    WHERE t.depth < 5
)
SELECT
    t.depth,
    COUNT(DISTINCT t.node)    AS nodes_at_this_depth,
    ROUND(SUM(z.revenue), 2)  AS total_revenue_brl
FROM tree     t
JOIN zip_leaf z ON LEFT(z.zip, t.depth) = t.node
GROUP BY t.depth
ORDER BY t.depth;
