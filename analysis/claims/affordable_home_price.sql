-- ============================================================================
-- Claim: affordable home price (AH) at p50 / p80 / p95 household income.
--
-- AH = income / 12 × 0.28 (front-end ratio) ÷ payment factor (7%, 30y)
-- ÷ 0.95 (5% down): the highest price whose mortgage takes 28% of income.
--
-- Income averages reported:
--   a. listing-weighted AVG over the filtered listings (per variant;
--      the published figure is variant 3)
--   b. unweighted mean of the 78 municipal values in census_income
--   (The ACS island-wide median is not in the database.)
-- Status is not used.
--
-- The BASE block is identical in every analysis/claims/*.sql file
-- (tests/test_claims_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/affordable_home_price.sql
-- ============================================================================

SET default_transaction_read_only = on;

-- 1. Listing-weighted income averages, per variant
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
           AVG(median_income) AS i50, AVG(income_p80) AS i80, AVG(income_p95) AS i95
    FROM variants
    GROUP BY variant
)
SELECT 'a_listing_weighted' AS income_source, variant, n,
       round(i50) AS income_p50, round(i50 / 12 * 0.28 / pmt_factor / 0.95) AS ah_p50,
       round(i80) AS income_p80, round(i80 / 12 * 0.28 / pmt_factor / 0.95) AS ah_p80,
       round(i95) AS income_p95, round(i95 / 12 * 0.28 / pmt_factor / 0.95) AS ah_p95
FROM agg, k
ORDER BY variant;

-- 2. Unweighted mean of municipal values
WITH k AS (
    SELECT (0.07 / 12) * power(1 + 0.07 / 12, 360) / (power(1 + 0.07 / 12, 360) - 1) AS pmt_factor
)
SELECT 'b_unweighted_78_municipalities' AS income_source, COUNT(*) AS municipalities,
       round(AVG(median_income)) AS income_p50,
       round(AVG(median_income) / 12 * 0.28 / pmt_factor / 0.95) AS ah_p50,
       round(AVG(income_p80)) AS income_p80,
       round(AVG(income_p80) / 12 * 0.28 / pmt_factor / 0.95) AS ah_p80,
       round(AVG(income_p95)) AS income_p95,
       round(AVG(income_p95) / 12 * 0.28 / pmt_factor / 0.95) AS ah_p95
FROM census_income, k
GROUP BY pmt_factor;
