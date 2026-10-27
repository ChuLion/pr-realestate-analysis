-- ============================================================================
-- Claim: per municipality × property type — n, median price, municipal
-- median household income, mortgage on the median listing as % of median
-- monthly income, price p25 / p75. Flags: n < 10 (do not publish the
-- cell), n < 30 (publish with a small-sample caveat). snapshot_window
-- ("Mar-Jun 2026") is the min-max month range of scraped_at over the
-- variant's rows, the same on every row of a variant.
--
-- Levels: island (property_type all / casa / apartamento; income is the
-- listing-weighted AVG of municipal medians, as in headline_pct_income.sql,
-- so island/all reproduces the headline), municipality (the 78 census
-- municipios; San Juan, Carolina, Humacao and Toa Baja sub-areas rolled
-- up), sub_area (Condado-Miramar, Hato Rey, Río Piedras, Santurce,
-- Viejo SJ, Isla Verde, Palmas, Levittown; parent municipality's income).
-- Same formula and filters as headline_pct_income.sql. Status is not
-- used. analysis/exports/muni_type_summary.csv is variant 3 of this query.
--
-- The BASE block is identical in every analysis/claims/*.sql file
-- (tests/test_claims_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/muni_type_summary.sql
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
cells AS (
    SELECT variant,
           CASE WHEN GROUPING(municipality_normalized) = 1 THEN 'island'
                WHEN GROUPING(sub_area) = 0 THEN 'sub_area'
                ELSE 'municipality' END AS level,
           municipality_normalized AS municipality, sub_area,
           CASE WHEN GROUPING(property_type_n) = 1 THEN 'all' ELSE property_type_n END AS property_type,
           COUNT(*) AS n,
           (percentile_cont(0.5)  WITHIN GROUP (ORDER BY price))::numeric AS median_price,
           (percentile_cont(0.25) WITHIN GROUP (ORDER BY price))::numeric AS price_p25,
           (percentile_cont(0.75) WITHIN GROUP (ORDER BY price))::numeric AS price_p75,
           AVG(median_income) AS median_income
    FROM (SELECT *, nullif(split_part(municipality, ' - ', 2), '') AS sub_area FROM variants) v
    GROUP BY GROUPING SETS (
        (variant),
        (variant, property_type_n),
        (variant, municipality_normalized, property_type_n),
        (variant, municipality_normalized, sub_area, property_type_n))
    HAVING NOT (GROUPING(sub_area) = 0 AND sub_area IS NULL)
),
snapshot AS (
    SELECT variant,
           CASE WHEN extract(year FROM MIN(scraped_at)) = extract(year FROM MAX(scraped_at))
                THEN to_char(MIN(scraped_at), 'Mon') || '-' || to_char(MAX(scraped_at), 'Mon YYYY')
                ELSE to_char(MIN(scraped_at), 'Mon YYYY') || '-' || to_char(MAX(scraped_at), 'Mon YYYY')
           END AS snapshot_window
    FROM variants
    GROUP BY variant
)
SELECT variant, level, municipality, sub_area, property_type, n,
       round(median_price) AS median_price,
       round(median_income) AS median_income,
       round(100 * median_price * 0.95 * pmt_factor / (median_income / 12), 1) AS pct_of_income,
       round(price_p25) AS price_p25,
       round(price_p75) AS price_p75,
       n < 10 AS flag_n_lt_10,
       n < 30 AS flag_n_lt_30,
       snapshot_window
FROM cells JOIN snapshot USING (variant), k
ORDER BY variant, CASE level WHEN 'island' THEN 1 WHEN 'municipality' THEN 2 ELSE 3 END,
         municipality, sub_area, property_type;
