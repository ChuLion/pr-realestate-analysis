-- ============================================================================
-- Barrio spelling variants — entity resolution review (SELECT only)
--
-- Sources: listings, listings_sold, rentals, barrio_crim_samples. Barrio
-- names repeat across municipalities, so every comparison is within a
-- municipality (municipality_normalized), never island-wide.
--
-- match_key = lower(unaccent(trim, collapsed whitespace)). Spellings that
-- share a match_key are HIGH: they differ only by case, accents or
-- whitespace, and migration 011 writes them to barrio_canonical.
-- REVIEW groups are never merged: they share a looser key (punctuation
-- removed, articles de/del/la/las/los/el/en/y dropped, common abbreviations
-- expanded), or a 30-character listing/rental name is the prefix of a
-- longer name (listings and rentals store at most 30 characters).
-- A leading "Type -" prefix ("Barrio -", "Urbanizacion -", "Sector -") is
-- split off for comparison; as of 2026-10-23 no barrio value has one (the
-- prefix appears only in titles).
--
-- The barrio_canonical SELECT block is identical in migration 011
-- (tests/test_barrio_canonical_sql.py). Query 5 checks the table against it.
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/barrio_variants.sql
-- ============================================================================

SET default_transaction_read_only = on;

-- 1. Rows with a "Type -" prefix in the barrio column, per source
SELECT src, COUNT(*) AS rows,
       COUNT(*) FILTER (WHERE barrio ~* '^\s*(barrio|urbanizaci[oó]n|urb\.?|sector|condominio|reparto|residencial|comunidad|parcelas)\s*-') AS type_prefixed
FROM (SELECT 'listings' AS src, barrio FROM listings
      UNION ALL SELECT 'listings_sold', barrio FROM listings_sold
      UNION ALL SELECT 'rentals', barrio FROM rentals
      UNION ALL SELECT 'barrio_crim_samples', barrio FROM barrio_crim_samples) x
GROUP BY src ORDER BY src;

-- 2. HIGH groups: rows per spelling and source (L listings, S sold, R rentals, C CRIM samples)
WITH raw AS (
    SELECT 'L' AS src, municipality_normalized AS municipality, barrio FROM listings
    UNION ALL SELECT 'S', municipality_normalized, barrio FROM listings_sold
    UNION ALL SELECT 'R', municipality_normalized, barrio FROM rentals
    UNION ALL SELECT 'C', municipality_normalized, barrio FROM barrio_crim_samples
), k AS (
    SELECT src, municipality, barrio,
           lower(unaccent(regexp_replace(trim(barrio), '\s+', ' ', 'g'))) AS match_key
    FROM raw
), grp AS (
    SELECT municipality, match_key FROM k GROUP BY 1, 2 HAVING COUNT(DISTINCT barrio) > 1
), per_spelling AS (
    SELECT municipality, match_key, barrio,
           string_agg(src || '=' || n, ' ' ORDER BY src) AS rows_by_source
    FROM (SELECT municipality, match_key, barrio, src, COUNT(*) AS n FROM k GROUP BY 1, 2, 3, 4) c
    JOIN grp USING (municipality, match_key)
    GROUP BY 1, 2, 3
)
SELECT municipality, match_key,
       string_agg('"' || barrio || '" ' || rows_by_source, '  |  ' ORDER BY barrio) AS spellings
FROM per_spelling
GROUP BY municipality, match_key
ORDER BY municipality, match_key;

-- 3. REVIEW groups (never auto-merged): same looser key, different match_key
WITH
-- BEGIN barrio_variants LOOSE
raw AS (
    SELECT 'L' AS src, municipality_normalized AS municipality, barrio FROM listings
    UNION ALL SELECT 'S', municipality_normalized, barrio FROM listings_sold
    UNION ALL SELECT 'R', municipality_normalized, barrio FROM rentals
    UNION ALL SELECT 'C', municipality_normalized, barrio FROM barrio_crim_samples
), k AS (
    SELECT src, municipality, barrio,
           lower(unaccent(regexp_replace(trim(barrio), '\s+', ' ', 'g'))) AS match_key
    FROM raw
), l AS (
    SELECT *, trim(regexp_replace(
        regexp_replace(regexp_replace(regexp_replace(regexp_replace(
        regexp_replace(regexp_replace(regexp_replace(regexp_replace(
            regexp_replace(match_key, '[[:punct:]’]', ' ', 'g'),
            '\m(de|del|la|las|los|el|en|y)\M', ' ', 'g'),
            '\murb\M', 'urbanizacion', 'g'), '\mext\M', 'extension', 'g'),
            '\mres\M', 'residencial', 'g'), '\msta\M', 'santa', 'g'),
            '\msto\M', 'santo', 'g'), '\mpque\M', 'parque', 'g'),
            '\mrepto\M', 'reparto', 'g'),
        '\s+', ' ', 'g')) AS loose_key
    FROM k
)
-- END barrio_variants LOOSE
, grp AS (
    SELECT municipality, loose_key FROM l GROUP BY 1, 2 HAVING COUNT(DISTINCT match_key) > 1
), per_spelling AS (
    SELECT municipality, loose_key, barrio,
           string_agg(src || '=' || n, ' ' ORDER BY src) AS rows_by_source
    FROM (SELECT municipality, loose_key, barrio, src, COUNT(*) AS n FROM l GROUP BY 1, 2, 3, 4) c
    JOIN grp USING (municipality, loose_key)
    GROUP BY 1, 2, 3
)
SELECT 'articles/abbreviations/punctuation' AS review_rule, municipality,
       string_agg('"' || barrio || '" ' || rows_by_source, '  |  ' ORDER BY barrio) AS spellings
FROM per_spelling
GROUP BY municipality, loose_key
ORDER BY municipality, loose_key;

-- 4. REVIEW: 30-character listing/rental names that are the prefix of a longer name
WITH names AS (
    SELECT DISTINCT municipality_normalized AS municipality, barrio FROM listings
    UNION SELECT municipality_normalized, barrio FROM rentals
    UNION SELECT municipality_normalized, barrio FROM listings_sold
    UNION SELECT municipality_normalized, barrio FROM barrio_crim_samples
)
SELECT 'truncated at 30 characters' AS review_rule, a.municipality, a.barrio AS truncated, b.barrio AS longer
FROM names a
JOIN names b ON b.municipality = a.municipality
            AND length(a.barrio) = 30 AND length(b.barrio) > 30
            AND left(lower(unaccent(b.barrio)), 30) = lower(unaccent(a.barrio))
ORDER BY 2, 3;

-- 5. barrio_canonical (migration 011) matches the SELECT that builds it:
--    both counts must be 0
WITH built AS (
-- BEGIN barrio_canonical SELECT
WITH raw AS (
    SELECT municipality_normalized AS municipality, barrio FROM public.listings
    UNION ALL SELECT municipality_normalized, barrio FROM public.listings_sold
    UNION ALL SELECT municipality_normalized, barrio FROM public.rentals
    UNION ALL SELECT municipality_normalized, barrio FROM public.barrio_crim_samples
), spellings AS (
    SELECT municipality, barrio AS raw_name, COUNT(*) AS n,
           regexp_replace(trim(barrio), '\s+', ' ', 'g') AS ws_name,
           lower(unaccent(regexp_replace(trim(barrio), '\s+', ' ', 'g'))) AS match_key
    FROM raw
    WHERE barrio IS NOT NULL
    GROUP BY municipality, barrio
), high_groups AS (
    SELECT municipality, match_key,
           (array_agg(ws_name ORDER BY n DESC, raw_name))[1] AS canonical_name
    FROM spellings
    GROUP BY municipality, match_key
    HAVING COUNT(*) > 1
)
SELECT s.municipality, s.raw_name, g.canonical_name,
       coalesce(nullif(concat_ws('+',
           CASE WHEN s.raw_name <> s.ws_name THEN 'whitespace' END,
           CASE WHEN unaccent(s.ws_name) <> unaccent(g.canonical_name) THEN 'case' END,
           CASE WHEN lower(s.ws_name) <> lower(g.canonical_name) THEN 'accent' END), ''),
           'canonical') AS rule,
       'HIGH' AS confidence
FROM spellings s
JOIN high_groups g USING (municipality, match_key)
-- END barrio_canonical SELECT
)
SELECT 'in SELECT, not in table' AS check, COUNT(*) FROM (
    SELECT * FROM built EXCEPT SELECT municipality, raw_name, canonical_name, rule, confidence FROM barrio_canonical) a
UNION ALL
SELECT 'in table, not in SELECT', COUNT(*) FROM (
    SELECT municipality, raw_name, canonical_name, rule, confidence FROM barrio_canonical EXCEPT SELECT * FROM built) b;
