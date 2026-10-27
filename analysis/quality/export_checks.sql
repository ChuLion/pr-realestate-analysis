-- ============================================================================
-- Export checks (SELECT only): recompute values on screen from the exported
-- files themselves. The CSV is read into a psql variable, so run from the
-- repo root with psql (not a GUI client).
--
-- 1. muni_type_summary.csv: pct_of_income recomputed from the exported
--    median_price and median_income with the default parameters (5% down,
--    7%, 30 years; the 28% front-end ratio only enters affordable prices)
--    must equal the exported pct_of_income. Reports the maximum absolute
--    difference.
-- 2. census_income.csv equals the census_income table.
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/export_checks.sql
-- ============================================================================

SET default_transaction_read_only = on;

\set muni_csv `cat analysis/exports/muni_type_summary.csv`

WITH k AS (
    SELECT (0.07 / 12) * power(1 + 0.07 / 12, 360) / (power(1 + 0.07 / 12, 360) - 1) AS pmt_factor
), lines AS (
    SELECT line, ord
    FROM regexp_split_to_table(:'muni_csv', '\n') WITH ORDINALITY AS t(line, ord)
    WHERE ord > 1 AND line <> ''
), rows AS (
    SELECT split_part(line, ',', 1) AS level, split_part(line, ',', 2) AS municipality,
           split_part(line, ',', 3) AS sub_area, split_part(line, ',', 4) AS property_type,
           split_part(line, ',', 6)::numeric AS median_price,
           split_part(line, ',', 7)::numeric AS median_income,
           split_part(line, ',', 8)::numeric AS pct_exported
    FROM lines
), recomputed AS (
    SELECT *, round(100 * median_price * 0.95 * pmt_factor / (median_income / 12), 1) AS pct_recomputed
    FROM rows, k
)
SELECT COUNT(*) AS rows_checked,
       COUNT(*) FILTER (WHERE pct_recomputed = pct_exported) AS exact_match,
       MAX(abs(pct_recomputed - pct_exported)) AS max_abs_diff,
       string_agg(level || '/' || municipality || '/' || sub_area || '/' || property_type
                  || ' ' || pct_exported || ' vs ' || pct_recomputed, '; ')
           FILTER (WHERE pct_recomputed <> pct_exported) AS differing_rows
FROM recomputed;

-- 2. census_income.csv equals the census_income table (all 78 municipios)
\set census_csv `cat analysis/exports/census_income.csv`

WITH rows AS (
    SELECT split_part(line, ',', 1) AS municipality,
           split_part(line, ',', 2)::numeric AS median_income,
           split_part(line, ',', 3)::numeric AS income_p20,
           split_part(line, ',', 4)::numeric AS income_p50,
           split_part(line, ',', 5)::numeric AS income_p80,
           split_part(line, ',', 6)::numeric AS income_p95
    FROM regexp_split_to_table(:'census_csv', '\n') WITH ORDINALITY AS t(line, ord)
    WHERE ord > 1 AND line <> ''
)
SELECT (SELECT COUNT(*) FROM rows) AS exported, (SELECT COUNT(*) FROM census_income) AS in_table,
       COUNT(*) FILTER (WHERE (r.median_income, r.income_p20, r.income_p50, r.income_p80, r.income_p95)
                              IS DISTINCT FROM
                              (c.median_income, c.income_p20, c.median_income, c.income_p80, c.income_p95)) AS mismatches,
       (SELECT income_p80 || ' / ' || income_p95 FROM rows WHERE municipality = 'Moca') AS moca_p80_p95
FROM rows r
FULL JOIN census_income c ON c.municipality_normalized = r.municipality;
