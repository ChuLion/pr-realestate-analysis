-- ============================================================================
-- Claim: island headline — mortgage on the median listing as a share of
-- median monthly household income.
--
-- Formula: MEDIAN(price) × 0.95 (5% down) × monthly
-- payment factor (7%, 30 years) ÷ (AVG(median_income) / 12). AVG is over
-- listing rows, i.e. listing-weighted. Filters: for sale, casa/apartamento,
-- $20,000–$2,400,000. Status is not used.
--
-- Variants: 1 = first scraped on or before 2026-04-07, no dedup;
-- 2 = full snapshot, no dedup; 3 = full snapshot, dedup primaries only
-- (the published figure).
--
-- The BASE block is identical in every analysis/claims/*.sql file
-- (tests/test_claims_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/headline_pct_income.sql
-- ============================================================================

SET default_transaction_read_only = on;

WITH
-- BEGIN claims BASE
base AS (
    SELECT v.municipality, v.municipality_normalized, v.property_type_n, v.price, v.scraped_at,
           v.median_income, v.income_p80, v.income_p95, l.is_primary_in_group
    FROM v_market_unified v
    JOIN listings l ON l.id::text = v.id
    WHERE v.listing_type = 'sale'
      AND v.property_type_n IN ('casa', 'apartamento')
      AND v.price BETWEEN 20000 AND 2400000
),
variants AS (
    SELECT '1_apr7_no_dedup' AS variant, * FROM base WHERE scraped_at < DATE '2026-04-08'
    UNION ALL
    SELECT '2_full_no_dedup', * FROM base
    UNION ALL
    SELECT '3_full_dedup', * FROM base WHERE is_primary_in_group IS DISTINCT FROM FALSE
),
k AS (
    SELECT (0.07 / 12) * power(1 + 0.07 / 12, 360) / (power(1 + 0.07 / 12, 360) - 1) AS pmt_factor
),
-- END claims BASE
agg AS (
    SELECT variant, COUNT(*) AS n,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY price))::numeric AS median_price,
           AVG(median_income) AS avg_median_income
    FROM variants
    GROUP BY variant
)
SELECT variant, n, median_price,
       round(avg_median_income) AS avg_median_income,
       round(median_price * 0.95 * pmt_factor, 2) AS monthly_payment,
       round(100 * median_price * 0.95 * pmt_factor / (avg_median_income / 12), 1) AS pct_of_income
FROM agg, k
ORDER BY variant;
