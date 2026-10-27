-- ============================================================================
-- Export: listing-price histogram at $5,000 resolution, for the dashboard
-- (analysis/exports/price_bins.csv). Variant 3 only (full snapshot, dedup
-- primaries), same filters as every claim. Bins run from $20,000 to
-- $2,400,000; bin_floor is the lower edge, a bin covers [floor, floor+5000)
-- and the last bin also holds $2,400,000 exactly.
--
-- scope island: property_type all / casa / apartamento, every listing.
-- scope municipality: the 78 census municipios (sub-areas rolled up), only
-- cells with n >= 10; smaller cells are counted in island scope only.
-- Zero-count bins are omitted. Checks: price_bins_checks.sql.
--
-- The BASE and BINS blocks are identical across analysis/claims/*.sql
-- (tests/test_claims_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/price_bins.sql
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
-- BEGIN price_bins BINS
bins AS (
    SELECT municipality_normalized AS municipality, property_type_n, price,
           LEAST(20000 + floor((price - 20000) / 5000) * 5000, 2395000) AS bin_floor
    FROM variants
    WHERE variant = '3_full_dedup'
),
cells AS (
    SELECT municipality, property_type_n, COUNT(*) AS cell_n FROM bins GROUP BY 1, 2
)
-- END price_bins BINS
SELECT 'island' AS scope, NULL AS municipality,
       CASE WHEN GROUPING(property_type_n) = 1 THEN 'all' ELSE property_type_n END AS property_type,
       bin_floor, COUNT(*) AS n
FROM bins
GROUP BY GROUPING SETS ((bin_floor), (property_type_n, bin_floor))
UNION ALL
SELECT 'municipality', b.municipality, b.property_type_n, b.bin_floor, COUNT(*)
FROM bins b
JOIN cells c USING (municipality, property_type_n)
WHERE c.cell_n >= 10
GROUP BY b.municipality, b.property_type_n, b.bin_floor
ORDER BY 1, 2 NULLS FIRST, 3, 4;
