-- =============================================================================
-- 02_trend_analysis.sql — Month-over-month growth and moving averages
-- =============================================================================
-- Target: PostgreSQL 17
-- Run:    psql -d olist -f queries/02_trend_analysis.sql
--
-- Conventions from 01_ranking.sql carry over: revenue is SUM(order_items.price),
-- and only delivered orders count.
--
-- THE ANALYSIS WINDOW: 2017-01 THROUGH 2018-08
-- --------------------------------------------
-- Orders exist from 2016-09-04 to 2018-10-17, but the usable trend window is
-- narrower, for two independent reasons. Both were found by profiling, and both
-- would produce badly wrong charts if ignored.
--
-- 1. THE HEAD IS NOISE, AND ONE MONTH IS MISSING ENTIRELY.
--      2016-09    1 delivered order        135 BRL
--      2016-10  265 delivered orders    40,325 BRL
--      2016-11  NO ORDERS AT ALL — the month does not exist in the data
--      2016-12    1 delivered order         11 BRL
--    Growth rates computed against a single 11 BRL order are meaningless.
--
-- 2. THE TAIL IS CENSORED BY DELIVERY LAG, NOT BY DEMAND.
--    2018-09 has 16 orders and 2018-10 has 4, but ZERO of them are delivered —
--    the dataset was extracted before they completed. Charting those months
--    shows revenue falling off a cliff, which is an artefact of the export date,
--    not a business event. This is right-censoring, and the only honest
--    treatment is to exclude the affected periods and say so.
--
-- Restricting to 2017-01..2018-08 keeps 20 complete months. Every query below
-- applies this window, and Q1 shows exactly what happens when you do not.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Query 1 — Why month-over-month growth needs a date spine
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   What was month-over-month revenue growth in the platform's first months?
--
-- WHY THIS TECHNIQUE
--   This query deliberately shows the WRONG answer alongside the right one,
--   because the failure is silent and produces a plausible-looking number.
--
--   LAG() returns the previous ROW in the partition, not the previous MONTH. If
--   a month has no orders it produces no row, so LAG happily reaches across the
--   gap and compares December against October while labelling it "last month".
--   Nothing errors; the report is simply wrong.
--
--   The fix is a date spine: generate_series produces every month in the range,
--   and a LEFT JOIN attaches revenue where it exists. Now every month occupies a
--   row, missing months are visibly zero, and LAG genuinely means "last month".
--
-- HOW TO READ THE OUTPUT
--   * 2016-11 appears only in the spine version. It is absent from the raw data.
--   * naive_prev_month shows LAG's actual reference month. For 2016-12 it reads
--     2016-10 — two months back, labelled as "previous". That is the alignment
--     bug, and it is completely silent.
--   * For 2016-12 the spine reports NULL rather than a percentage, because the
--     true previous month is zero and growth from zero is undefined. NULLIF
--     produces that NULL instead of a division-by-zero error.
--
--   TWO SEPARATE DEFECTS, ONLY ONE OF WHICH THE SPINE FIXES
--   Note that spine_mom_pct still reports +1,025,573% for 2017-01. The spine did
--   not fix that, and was never going to: the reference month is now genuinely
--   December, so the alignment is correct. The problem is that December holds a
--   single 11 BRL order, so the denominator is tiny and the ratio explodes.
--
--   These are independent failures needing independent fixes:
--     alignment       -> the date spine (this query)
--     tiny denominator-> restrict the analysis window (every query after this)
--
--   Fixing only the first and declaring victory is how a wrong number survives
--   review, because it now comes from correct-looking code.
-- -----------------------------------------------------------------------------
\echo '=== Q1. The LAG trap: naive month-over-month vs a gapless date spine ==='

WITH monthly_revenue AS (
    -- Raw aggregate. Months with no orders simply do not appear.
    SELECT
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp < '2017-04-01'
    GROUP BY 1
),
naive AS (
    -- What you get by trusting LAG over a sparse series.
    SELECT
        month,
        revenue,
        LAG(month)   OVER (ORDER BY month) AS naive_prev_month,
        LAG(revenue) OVER (ORDER BY month) AS naive_prev_revenue
    FROM monthly_revenue
),
spine AS (
    -- Every calendar month in the range, whether or not it had orders.
    SELECT generate_series(
               '2016-09-01'::date, '2017-03-01'::date, '1 month'
           )::date AS month
),
corrected AS (
    SELECT
        s.month,
        COALESCE(m.revenue, 0)                            AS revenue,
        LAG(COALESCE(m.revenue, 0)) OVER (ORDER BY s.month) AS true_prev_revenue
    FROM spine s
    LEFT JOIN monthly_revenue m ON m.month = s.month
)
SELECT
    to_char(c.month, 'YYYY-MM')              AS month,
    ROUND(c.revenue, 2)                      AS revenue_brl,
    to_char(n.naive_prev_month, 'YYYY-MM')   AS naive_prev_month,
    ROUND(100.0 * (n.revenue - n.naive_prev_revenue)
                / NULLIF(n.naive_prev_revenue, 0), 1) AS naive_mom_pct,
    ROUND(100.0 * (c.revenue - c.true_prev_revenue)
                / NULLIF(c.true_prev_revenue, 0), 1)  AS spine_mom_pct
FROM corrected c
LEFT JOIN naive n ON n.month = c.month
ORDER BY c.month;


-- -----------------------------------------------------------------------------
-- Query 2 — Month-over-month growth across the usable window
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   How fast is revenue growing month to month, and which months broke trend?
--
-- WHY THIS TECHNIQUE
--   LAG(revenue) OVER (ORDER BY month) reads the previous row's value without a
--   self-join. The pre-window alternative is joining the table to itself on
--   `month = month - interval '1 month'`, which needs the same date-spine
--   handling anyway and costs a second scan.
--
--   NULLIF guards the division: any month whose predecessor is zero would raise
--   a division-by-zero error, and NULLIF converts that to NULL — an honest
--   "undefined" rather than a crash or a fake 0%.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q2. Month-over-month revenue growth, 2017-01 to 2018-08 ==='

WITH spine AS (
    SELECT generate_series(
               '2017-01-01'::date, '2018-08-01'::date, '1 month'
           )::date AS month
),
monthly AS (
    SELECT
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue,
        COUNT(DISTINCT o.order_id)                            AS orders
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
),
series AS (
    SELECT
        s.month,
        COALESCE(m.revenue, 0) AS revenue,
        COALESCE(m.orders,  0) AS orders
    FROM spine s
    LEFT JOIN monthly m ON m.month = s.month
)
SELECT
    to_char(month, 'YYYY-MM')                  AS month,
    ROUND(revenue, 2)                          AS revenue_brl,
    orders,
    ROUND(revenue / NULLIF(orders, 0), 2)      AS avg_order_value_brl,
    ROUND(LAG(revenue) OVER (ORDER BY month), 2) AS prev_month_brl,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
                / NULLIF(LAG(revenue) OVER (ORDER BY month), 0), 1) AS mom_growth_pct
FROM series
ORDER BY month;


-- -----------------------------------------------------------------------------
-- Query 3 — Moving averages, and why ROWS and RANGE are not interchangeable
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   What does the revenue trend look like once month-to-month noise is smoothed
--   out, and does the choice of window frame change the answer?
--
-- WHY THIS TECHNIQUE
--   A moving average needs an explicit frame. The two options mean different
--   things, and this data proves it:
--
--     ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
--         counts ROWS. Three rows back, regardless of what dates they hold.
--
--     RANGE BETWEEN INTERVAL '2 months' PRECEDING AND CURRENT ROW
--         counts VALUES. Only rows whose month falls inside the interval.
--
--   On a gapless series they agree. Across the 2016-11 gap they do not:
--   at 2016-12, ROWS averages Sep + Oct + Dec (three rows) and returns 13,490,
--   while RANGE averages only Oct + Dec (September is three calendar months
--   back, outside the interval) and returns 20,168.
--
--   ROWS is used for the headline moving average below because the spine
--   guarantees no gaps, which makes position and date equivalent — and ROWS is
--   cheaper, since RANGE with an interval must evaluate a bound per row.
--   The lesson is that ROWS is only safe once you have guaranteed the gaps away.
--
--   Both frames are shown on the RAW ungapped series first, to make the
--   difference visible rather than merely asserted.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q3a. ROWS vs RANGE across the 2016-11 gap (raw series, no spine) ==='

WITH monthly AS (
    SELECT
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp < '2017-04-01'
    GROUP BY 1
)
SELECT
    to_char(month, 'YYYY-MM') AS month,
    ROUND(revenue, 2)         AS revenue_brl,
    ROUND(AVG(revenue) OVER (ORDER BY month
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)   AS ma_3mo_rows,
    ROUND(AVG(revenue) OVER (ORDER BY month
              RANGE BETWEEN INTERVAL '2 months' PRECEDING
                        AND CURRENT ROW), 2)                  AS ma_3mo_range,
    COUNT(*) OVER (ORDER BY month
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)       AS rows_in_frame,
    COUNT(*) OVER (ORDER BY month
              RANGE BETWEEN INTERVAL '2 months' PRECEDING
                        AND CURRENT ROW)                      AS range_in_frame
FROM monthly
ORDER BY month;

\echo ''
\echo '=== Q3b. 3- and 6-month moving averages on the clean window ==='

WITH spine AS (
    SELECT generate_series(
               '2017-01-01'::date, '2018-08-01'::date, '1 month'
           )::date AS month
),
monthly AS (
    SELECT
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
),
series AS (
    SELECT s.month, COALESCE(m.revenue, 0) AS revenue
    FROM spine s
    LEFT JOIN monthly m ON m.month = s.month
)
SELECT
    to_char(month, 'YYYY-MM') AS month,
    ROUND(revenue, 2)         AS revenue_brl,
    ROUND(AVG(revenue) OVER (ORDER BY month
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS ma_3mo,
    ROUND(AVG(revenue) OVER (ORDER BY month
              ROWS BETWEEN 5 PRECEDING AND CURRENT ROW), 2) AS ma_6mo,
    -- Deviation from the 3-month trend. Positive means the month outperformed
    -- its own recent baseline, which is what "broke trend" actually means.
    ROUND(100.0 * (revenue - AVG(revenue) OVER (ORDER BY month
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))
        / NULLIF(AVG(revenue) OVER (ORDER BY month
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0), 1) AS pct_vs_ma_3mo
FROM series
ORDER BY month;


-- -----------------------------------------------------------------------------
-- Query 4 — Year-over-year growth
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Is the business still growing once seasonality is removed, and is the rate
--   accelerating or slowing?
--
-- WHY THIS TECHNIQUE
--   LAG takes an offset: LAG(revenue, 12) reads the row twelve positions back,
--   which on a monthly spine is exactly the same month last year. This is the
--   standard way to strip seasonality — November's spike compares against the
--   previous November rather than against October.
--
--   The offset argument is only trustworthy BECAUSE of the spine. On the raw
--   series, twelve rows back could be any date at all. This is the same lesson
--   as Q1, one step more dangerous, because a wrong YoY number looks reasonable.
--
--   LEAD is the mirror image and is included to show next month's actual result
--   alongside each row — useful for eyeballing whether a spike sustained.
--
-- A BUG THIS QUERY ORIGINALLY HAD, KEPT HERE AS A WARNING
--   The first version filtered `WHERE month >= '2018-01-01'` in the same SELECT
--   that computed LAG(revenue, 12). Every YoY value came back NULL.
--
--   The reason is the clause evaluation order: WHERE runs BEFORE window
--   functions. The filter cut the input to 8 rows, and only then did LAG try to
--   look 12 rows back — past the start of the data. It returned NULL for every
--   row, silently, with no error.
--
--   The fix is the `with_comparisons` CTE below: compute the window functions
--   over the FULL 20-month series first, then filter the result in the outer
--   query. Same rule as the top-N filtering in 01_ranking.sql, and the failure
--   here is nastier because an empty column looks like missing data rather than
--   a mistake.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q4. Year-over-year growth, 2018 vs 2017 ==='

WITH spine AS (
    SELECT generate_series(
               '2017-01-01'::date, '2018-08-01'::date, '1 month'
           )::date AS month
),
monthly AS (
    SELECT
        date_trunc('month', o.order_purchase_timestamp)::date AS month,
        SUM(oi.price)                                         AS revenue
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 1
),
series AS (
    SELECT s.month, COALESCE(m.revenue, 0) AS revenue
    FROM spine s
    LEFT JOIN monthly m ON m.month = s.month
),
with_comparisons AS (
    -- Window functions are computed over the FULL 20-month series. Filtering
    -- before this point would leave LAG nothing to reach back to.
    SELECT
        month,
        revenue,
        LAG(revenue, 12) OVER (ORDER BY month) AS same_month_last_year,
        LEAD(revenue)    OVER (ORDER BY month) AS next_month
    FROM series
)
SELECT
    to_char(month, 'YYYY-MM')            AS month,
    ROUND(revenue, 2)                    AS revenue_brl,
    ROUND(same_month_last_year, 2)       AS same_month_last_year_brl,
    ROUND(100.0 * (revenue - same_month_last_year)
                / NULLIF(same_month_last_year, 0), 1) AS yoy_growth_pct,
    ROUND(next_month, 2)                 AS next_month_brl
FROM with_comparisons
-- The first 12 months have no prior year to compare against, so YoY is NULL by
-- definition. Filtering them out here — AFTER the window functions have run —
-- is safe, and more honest than printing a column of empty cells.
WHERE month >= '2018-01-01'
ORDER BY month;


-- -----------------------------------------------------------------------------
-- Query 5 — Which categories are gaining and losing momentum?
-- -----------------------------------------------------------------------------
-- BUSINESS QUESTION
--   Comparing the most recent quarter against the same quarter a year earlier,
--   which categories are growing fastest and which are shrinking?
--
-- WHY THIS TECHNIQUE
--   PARTITION BY category restarts the LAG sequence for every category, so one
--   pass computes a per-category year-over-year comparison. Without partitioning,
--   LAG would run off the end of one category and read the first row of the next,
--   silently comparing unrelated products.
--
--   Quarters are compared rather than single months to reduce noise: a small
--   category can swing wildly month to month on a handful of orders. The
--   minimum-revenue filter exists for the same reason — percentage growth on a
--   tiny base is technically correct and practically useless.
-- -----------------------------------------------------------------------------
\echo ''
\echo '=== Q5. Category momentum: 2018 Q2 vs 2017 Q2 ==='

WITH category_quarter AS (
    SELECT
        COALESCE(t.product_category_name_english,
                 p.product_category_name) AS category,
        date_trunc('quarter', o.order_purchase_timestamp)::date AS quarter,
        SUM(oi.price)                     AS revenue
    FROM order_items oi
    JOIN orders   o ON o.order_id   = oi.order_id
    JOIN products p ON p.product_id = oi.product_id
    LEFT JOIN product_category_translation t
           ON t.product_category_name = p.product_category_name
    WHERE o.order_status = 'delivered'
      AND p.product_category_name IS NOT NULL
      -- Both full quarters being compared, and nothing in between, so LAG(,4)
      -- is not needed and the comparison stays explicit.
      AND o.order_purchase_timestamp >= '2017-04-01'
      AND o.order_purchase_timestamp <  '2018-07-01'
    GROUP BY 1, 2
),
compared AS (
    SELECT
        category,
        SUM(revenue) FILTER (WHERE quarter = '2017-04-01') AS q2_2017,
        SUM(revenue) FILTER (WHERE quarter = '2018-04-01') AS q2_2018
    FROM category_quarter
    GROUP BY category
)
SELECT
    category,
    ROUND(q2_2017, 2) AS q2_2017_brl,
    ROUND(q2_2018, 2) AS q2_2018_brl,
    ROUND(100.0 * (q2_2018 - q2_2017) / NULLIF(q2_2017, 0), 1) AS yoy_pct,
    RANK() OVER (ORDER BY (q2_2018 - q2_2017) DESC)            AS growth_rank
FROM compared
-- Require meaningful volume in BOTH quarters: a category that did 200 BRL last
-- year and 2,000 this year shows +900% and tells you nothing.
WHERE q2_2017 >= 20000
  AND q2_2018 >= 20000
ORDER BY (q2_2018 - q2_2017) DESC
LIMIT 15;
