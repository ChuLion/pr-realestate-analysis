-- ============================================================================
-- Reconciliation: every value that must appear on the dashboard, read back
-- from the export file it comes from (analysis/exports/reconciliation.csv).
-- Values are parsed from the exported CSVs themselves, so this also checks
-- that the exports say what RESULTS.md says. Two values are not in any
-- export and are computed here from the claims base (variant 3): the
-- affordable price at $80,000 income and the share of listings at or
-- below it (same rule as price_histogram.sql query 1).
--
-- CSVs are read into psql variables: run from the repo root, after
-- analysis/exports/build_exports.sh has written them.
--
-- Run: psql -h localhost -d pr_realestate -f analysis/claims/reconciliation.sql
-- ============================================================================

SET default_transaction_read_only = on;

\set muni_csv `cat analysis/exports/muni_type_summary.csv`
\set ledger_csv `cat analysis/exports/conflict_ledger.csv`
\set tiers_csv `cat analysis/exports/near_duplicate_tiers.csv`
\set distress_csv `cat analysis/exports/distress_ledger.csv`

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
muni AS (
    SELECT split_part(line, ',', 1) AS level, split_part(line, ',', 2) AS municipality,
           split_part(line, ',', 4) AS property_type,
           split_part(line, ',', 5) AS n, split_part(line, ',', 6) AS median_price,
           split_part(line, ',', 7) AS median_income, split_part(line, ',', 8) AS pct_of_income,
           split_part(line, ',', 11) AS flag_n_lt_10, split_part(line, ',', 12) AS flag_n_lt_30
    FROM regexp_split_to_table(:'muni_csv', '\n') WITH ORDINALITY t(line, ord)
    WHERE ord > 1 AND line <> ''
),
ledger AS (
    -- issue is unquoted; description may be quoted (contains commas)
    SELECT split_part(line, ',', 1) AS issue,
           substring(line FROM '^[^,]*,(?:"(?:[^"]|"")*"|[^,]*),([0-9]+),') AS rows_affected
    FROM regexp_split_to_table(:'ledger_csv', '\n') WITH ORDINALITY t(line, ord)
    WHERE ord > 1 AND line <> ''
),
tiers AS (
    SELECT split_part(line, ',', 1) AS tier, split_part(line, ',', 2) AS pairs,
           split_part(line, ',', 3) AS listings_involved
    FROM regexp_split_to_table(:'tiers_csv', '\n') WITH ORDINALITY t(line, ord)
    WHERE ord > 1 AND line <> ''
),
distress AS (
    SELECT split_part(line, ',', 2) AS pattern, split_part(line, ',', 4) AS listings,
           split_part(line, ',', 5) AS distinct_properties
    FROM regexp_split_to_table(:'distress_csv', '\n') WITH ORDINALITY t(line, ord)
    WHERE ord > 1 AND line <> '' AND split_part(line, ',', 1) = 'island'
),
ah80 AS (
    SELECT round(80000 / 12.0 * 0.28 / pmt_factor / 0.95) AS ah FROM k
),
share80 AS (
    SELECT round(100.0 * COUNT(*) FILTER (WHERE price <= (SELECT ah FROM ah80)) / COUNT(*), 1) AS pct
    FROM variants WHERE variant = '3_full_dedup'
),
cells (municipality, property_type, ord) AS (
    VALUES ('Moca', 'casa', 1), ('Aguada', 'apartamento', 2), ('San Juan', 'apartamento', 3),
           ('Dorado', 'casa', 4), ('Ponce', 'casa', 5)
),
recon (sort, section, item, value, unit, source_file) AS (
    SELECT 10 + r.o, 'island', m.property_type || ': ' || r.metric, r.val, r.unit, 'analysis/exports/muni_type_summary.csv'
    FROM muni m
    CROSS JOIN LATERAL (VALUES (1, 'n', m.n, 'listings'), (2, 'median price', m.median_price, 'USD'),
                               (3, 'income used (listing-weighted municipal medians)', m.median_income, 'USD/year'),
                               (4, 'mortgage as % of income', m.pct_of_income, '%')) r(o, metric, val, unit)
    WHERE m.level = 'island'
    UNION ALL
    SELECT 30, 'island', 'affordable price at $80,000 income (28% of income, 5% down, 7%, 30y)',
           (SELECT ah FROM ah80)::text, 'USD', 'analysis/claims/price_histogram.sql (RESULTS.md)'
    UNION ALL
    SELECT 31, 'island', 'share of listings at or below the $80,000-income affordable price',
           (SELECT pct FROM share80)::text, '%', 'analysis/claims/price_histogram.sql (RESULTS.md)'
    UNION ALL
    SELECT 40 + c.ord * 10 + r.o, 'municipality', c.municipality || ' ' || c.property_type || ': ' || r.metric,
           r.val, r.unit, 'analysis/exports/muni_type_summary.csv'
    FROM cells c
    JOIN muni m ON m.level = 'municipality' AND m.municipality = c.municipality AND m.property_type = c.property_type
    CROSS JOIN LATERAL (VALUES (1, 'n', m.n, 'listings'), (2, 'median price', m.median_price, 'USD'),
                               (3, 'municipal median income', m.median_income, 'USD/year'),
                               (4, 'mortgage as % of income', m.pct_of_income, '%'),
                               (5, 'small sample (n < 30)', CASE m.flag_n_lt_30 WHEN 't' THEN 'yes' ELSE 'no' END, 'flag'),
                               (6, 'do not publish (n < 10)', CASE m.flag_n_lt_10 WHEN 't' THEN 'yes' ELSE 'no' END, 'flag')) r(o, metric, val, unit)
    UNION ALL
    SELECT 110 + r.o, 'dedup', r.label, l.rows_affected, r.unit, 'analysis/exports/conflict_ledger.csv'
    FROM ledger l
    JOIN (VALUES (1, 'duplicate groups', 'duplicate groups', 'groups'),
                 (2, 'duplicate rows (in a group)', 'listings in duplicate groups', 'listings'),
                 (3, 'duplicate excess', 'repeat copies excluded', 'listings')) r(o, issue, label, unit) USING (issue)
    UNION ALL
    SELECT 120 + r.o, 'near-duplicate candidates', 'tier ' || t.tier || ': ' || r.metric, r.val, r.unit,
           'analysis/exports/near_duplicate_tiers.csv'
    FROM tiers t
    CROSS JOIN LATERAL (VALUES (ascii(t.tier) * 2, 'pairs', t.pairs, 'pairs'),
                               (ascii(t.tier) * 2 + 1, 'listings involved', t.listings_involved, 'listings')) r(o, metric, val, unit)
    UNION ALL
    SELECT 400 + row_number() OVER (ORDER BY d.pattern) * 2 + r.o, 'distress wording', d.pattern || ': ' || r.metric,
           r.val, r.unit, 'analysis/exports/distress_ledger.csv'
    FROM distress d
    CROSS JOIN LATERAL (VALUES (0, 'listings', d.listings, 'listings'),
                               (1, 'distinct properties', d.distinct_properties, 'properties')) r(o, metric, val, unit)
)
SELECT section, item, value, unit, source_file
FROM recon
ORDER BY sort, item;
