-- ============================================================================
-- Claim: listing-price histogram and the share of listings a household
-- earning $80,000 can afford. Published threshold: $295,341.
--
-- $295,341 = 80,000 / 12 × 0.28 ÷ payment factor (7%, 30y) ÷ 0.95, the
-- same affordability rule as affordable_home_price.sql (query 2 shows it).
-- Bins are $50,000 wide, with an open last bin from $1,000,000. Status is
-- not used.
--
-- The BASE block is identical in every analysis/claims/*.sql file
-- (tests/test_claims_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/price_histogram.sql
-- ============================================================================

SET default_transaction_read_only = on;

-- 1. Share of listings at or below the $80,000-income affordable price
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
threshold AS (
    SELECT round(80000 / 12.0 * 0.28 / pmt_factor / 0.95) AS ah_80k FROM k
)
SELECT variant, COUNT(*) AS n, ah_80k,
       COUNT(*) FILTER (WHERE price <= ah_80k) AS n_affordable,
       round(100.0 * COUNT(*) FILTER (WHERE price <= ah_80k) / COUNT(*), 1) AS pct_affordable
FROM variants, threshold
GROUP BY variant, ah_80k
ORDER BY variant;

-- 2. Histogram: listings per $50,000 price bin
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
binned AS (
    SELECT variant, LEAST(floor(price / 50000) * 50000, 1000000) AS bin_start
    FROM variants
)
SELECT variant, bin_start,
       CASE WHEN bin_start = 1000000 THEN NULL ELSE bin_start + 49999 END AS bin_end,
       COUNT(*) AS n
FROM binned
GROUP BY variant, bin_start
ORDER BY variant, bin_start;
