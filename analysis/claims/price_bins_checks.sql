-- ============================================================================
-- Checks for price_bins.sql (variant 3).
-- 1. Bin sums equal each cell's n (island all/casa/apartamento, and every
--    municipality cell with n >= 10). Every row must read ok.
-- 2. Bin-resolution error: share of listings at or below the affordable
--    price for a given income, exact vs from $5,000 bins. Affordable price
--    = income / 12 × 0.28 ÷ payment factor (7%, 30y) ÷ 0.95. From bins:
--    lower = bins entirely at or below the threshold; upper = also the bin
--    containing it; interpolated = lower + the straddling bin pro-rated.
-- 3. The same for the $1,000 island bins (price_bins_island_1k.sql).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/price_bins_checks.sql
-- ============================================================================

SET default_transaction_read_only = on;

-- 1. Bin sums vs cell n
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
, binned AS (
    SELECT municipality, property_type_n, bin_floor, COUNT(*) AS n FROM bins GROUP BY 1, 2, 3
)
SELECT 'island all' AS cell, (SELECT SUM(n) FROM binned) AS bin_sum,
       (SELECT COUNT(*) FROM bins) AS cell_n,
       CASE WHEN (SELECT SUM(n) FROM binned) = (SELECT COUNT(*) FROM bins) THEN 'ok' ELSE 'MISMATCH' END AS result
UNION ALL
SELECT 'island ' || property_type_n, SUM(n), (SELECT COUNT(*) FROM bins b WHERE b.property_type_n = binned.property_type_n),
       CASE WHEN SUM(n) = (SELECT COUNT(*) FROM bins b WHERE b.property_type_n = binned.property_type_n) THEN 'ok' ELSE 'MISMATCH' END
FROM binned GROUP BY property_type_n
UNION ALL
SELECT 'municipality cells with n >= 10: ' || COUNT(*) || ' cells', SUM(bin_sum), SUM(cell_n),
       CASE WHEN bool_and(bin_sum = cell_n) THEN 'ok' ELSE 'MISMATCH' END
FROM (SELECT c.municipality, c.property_type_n, c.cell_n, SUM(b.n) AS bin_sum
      FROM cells c JOIN binned b USING (municipality, property_type_n)
      WHERE c.cell_n >= 10 GROUP BY 1, 2, 3) m;

-- 2. Bin-resolution error at several incomes (island, all types)
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
, thresholds AS (
    SELECT income, round(income / 12.0 * 0.28 / pmt_factor / 0.95) AS ah
    FROM (VALUES (40000), (60000), (80000), (120000)) i(income), k
), binned AS (
    SELECT bin_floor, COUNT(*) AS n FROM bins GROUP BY 1
), shares AS (
    SELECT t.income, t.ah,
           100.0 * (SELECT COUNT(*) FROM bins WHERE price <= t.ah) / (SELECT COUNT(*) FROM bins) AS exact,
           100.0 * (SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor + 5000 <= t.ah) / (SELECT COUNT(*) FROM bins) AS lower,
           100.0 * (SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor <= t.ah) / (SELECT COUNT(*) FROM bins) AS upper,
           100.0 * ((SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor + 5000 <= t.ah)
                    + (SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor <= t.ah AND bin_floor + 5000 > t.ah)
                      * (t.ah - floor((t.ah - 20000) / 5000) * 5000 - 20000) / 5000.0)
                 / (SELECT COUNT(*) FROM bins) AS interpolated
    FROM thresholds t
)
SELECT income, ah AS affordable_price,
       round(exact, 1) AS exact_pct, round(lower, 1) AS bins_lower, round(upper, 1) AS bins_upper,
       round(interpolated, 1) AS bins_interp,
       round(lower - exact, 1) AS gap_lower, round(upper - exact, 1) AS gap_upper,
       round(interpolated - exact, 1) AS gap_interp
FROM shares
ORDER BY income;

-- 3. $1,000 island bins (price_bins_island_1k.sql): bin sums, and the
--    bin-resolution error at the same incomes
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
-- BEGIN price_bins BINS_1K
bins_1k AS (
    SELECT property_type_n, price,
           LEAST(20000 + floor((price - 20000) / 1000) * 1000, 2399000) AS bin_floor
    FROM variants
    WHERE variant = '3_full_dedup'
)
-- END price_bins BINS_1K
, thresholds AS (
    SELECT income, round(income / 12.0 * 0.28 / pmt_factor / 0.95) AS ah
    FROM (VALUES (40000), (60000), (80000), (120000)) i(income), k
), binned AS (
    SELECT bin_floor, COUNT(*) AS n FROM bins_1k GROUP BY 1
), shares AS (
    SELECT t.income, t.ah,
           100.0 * (SELECT COUNT(*) FROM bins_1k WHERE price <= t.ah) / (SELECT COUNT(*) FROM bins_1k) AS exact,
           100.0 * (SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor + 1000 <= t.ah) / (SELECT COUNT(*) FROM bins_1k) AS lower,
           100.0 * (SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor <= t.ah) / (SELECT COUNT(*) FROM bins_1k) AS upper,
           100.0 * ((SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor + 1000 <= t.ah)
                    + (SELECT coalesce(SUM(n), 0) FROM binned WHERE bin_floor <= t.ah AND bin_floor + 1000 > t.ah)
                      * (t.ah - floor((t.ah - 20000) / 1000) * 1000 - 20000) / 1000.0)
                 / (SELECT COUNT(*) FROM bins_1k) AS interpolated
    FROM thresholds t
)
SELECT income, ah AS affordable_price,
       (SELECT SUM(n) FROM binned) AS bin_sum, (SELECT COUNT(*) FROM bins_1k) AS cell_n,
       round(exact, 1) AS exact_pct, round(lower, 1) AS bins_lower, round(upper, 1) AS bins_upper,
       round(interpolated, 1) AS bins_interp,
       round(lower - exact, 1) AS gap_lower, round(upper - exact, 1) AS gap_upper,
       round(interpolated - exact, 1) AS gap_interp
FROM shares
ORDER BY income;
