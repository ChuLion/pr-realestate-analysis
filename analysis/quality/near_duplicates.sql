-- ============================================================================
-- Near-duplicate candidates (SELECT only — nothing is flagged in the DB)
--
-- Population: the published base (v_market_unified sale rows, casa /
-- apartamento, $20,000–$2,400,000) restricted to dedup primaries, i.e.
-- variant 3 of analysis/claims/. Any two primaries are by construction
-- not in the same duplicate group. Pairs are blocked on municipality +
-- canonical barrio (barrio_canonical, migration 011) + type + bedrooms,
-- so there is no full self-join.
--
-- Tiers (A–C also need equal bathrooms; price within 2% of the higher):
--   A  both have coordinates, ≤ 25 m apart
--   B  coordinates missing on at least one side
--   C  both have coordinates, 25–100 m apart
--   D  attribute conflict: same price exactly, but bathrooms differ by
--      ≤ 0.5, or both have sqft and it differs (may overlap A–C)
-- Caveat: 5,873 listings in the base share only 2,315 distinct
-- coordinates, so 0 m often means "same pin", not "same unit".
--
-- Candidates for review only; the published figures do not use them.
-- The PAIRS block is identical in analysis/quality/conflict_ledger.sql
-- (tests/test_near_duplicates_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/near_duplicates.sql
-- ============================================================================

SET default_transaction_read_only = on;
SELECT setseed(0.23);  -- reproducible samples

-- 1. Pair counts, distinct listings involved, share of the base
WITH
-- BEGIN near_duplicates PAIRS
nd_base AS (
    SELECT l.id, l.municipality_normalized AS municipality,
           coalesce(bc.canonical_name, l.barrio) AS barrio,
           v.property_type_n, l.bedrooms, l.bathrooms, l.sqft, l.price,
           l.geom::geography AS geog, l.scraped_at, l.title
    FROM v_market_unified v
    JOIN listings l ON l.id::text = v.id
    LEFT JOIN barrio_canonical bc
           ON bc.municipality = l.municipality_normalized AND bc.raw_name = l.barrio
    WHERE v.listing_type = 'sale'
      AND v.property_type_n IN ('casa', 'apartamento')
      AND v.price BETWEEN 20000 AND 2400000
      AND l.is_primary_in_group IS DISTINCT FROM FALSE
),
nd_joined AS (
    SELECT a.id AS a_id, b.id AS b_id,
           ST_Distance(a.geog, b.geog) AS dist_m,
           a.bathrooms = b.bathrooms
               AND abs(a.price - b.price) <= 0.02 * greatest(a.price, b.price) AS abc_match,
           a.price = b.price
               AND ((a.bathrooms <> b.bathrooms AND abs(a.bathrooms - b.bathrooms) <= 0.5)
                    OR (a.sqft IS NOT NULL AND b.sqft IS NOT NULL AND a.sqft <> b.sqft)) AS d_match
    FROM nd_base a
    JOIN nd_base b ON b.municipality = a.municipality AND b.barrio = a.barrio
                  AND b.property_type_n = a.property_type_n AND b.bedrooms = a.bedrooms
                  AND a.id < b.id
),
nd_pairs AS (
    SELECT a_id, b_id, dist_m,
           CASE WHEN dist_m IS NULL THEN 'B'
                WHEN dist_m <= 25   THEN 'A'
                WHEN dist_m <= 100  THEN 'C' END AS tier
    FROM nd_joined WHERE abc_match
    UNION ALL
    SELECT a_id, b_id, dist_m, 'D' FROM nd_joined WHERE d_match
)
-- END near_duplicates PAIRS
,
ids AS (
    SELECT tier, a_id AS id FROM nd_pairs UNION SELECT tier, b_id FROM nd_pairs
)
SELECT t.tier, COUNT(DISTINCT p.a_id || '|' || p.b_id) AS pairs,
       (SELECT COUNT(*) FROM ids WHERE ids.tier = t.tier) AS listings_involved,
       (SELECT COUNT(*) FROM nd_base) AS base_primaries,
       round(100.0 * (SELECT COUNT(*) FROM ids WHERE ids.tier = t.tier) / (SELECT COUNT(*) FROM nd_base), 1) AS pct_of_base
FROM (VALUES ('A'), ('B'), ('C'), ('D')) t(tier)
LEFT JOIN nd_pairs p ON p.tier = t.tier AND p.tier IS NOT NULL
GROUP BY t.tier
ORDER BY t.tier;

-- 2. Test case: the $160,000 Sierra Bayamón casa (13-row dedup group plus
--    one listing with 1.0 baths instead of 1.5). Expected: a tier D pair.
WITH
-- BEGIN near_duplicates PAIRS
nd_base AS (
    SELECT l.id, l.municipality_normalized AS municipality,
           coalesce(bc.canonical_name, l.barrio) AS barrio,
           v.property_type_n, l.bedrooms, l.bathrooms, l.sqft, l.price,
           l.geom::geography AS geog, l.scraped_at, l.title
    FROM v_market_unified v
    JOIN listings l ON l.id::text = v.id
    LEFT JOIN barrio_canonical bc
           ON bc.municipality = l.municipality_normalized AND bc.raw_name = l.barrio
    WHERE v.listing_type = 'sale'
      AND v.property_type_n IN ('casa', 'apartamento')
      AND v.price BETWEEN 20000 AND 2400000
      AND l.is_primary_in_group IS DISTINCT FROM FALSE
),
nd_joined AS (
    SELECT a.id AS a_id, b.id AS b_id,
           ST_Distance(a.geog, b.geog) AS dist_m,
           a.bathrooms = b.bathrooms
               AND abs(a.price - b.price) <= 0.02 * greatest(a.price, b.price) AS abc_match,
           a.price = b.price
               AND ((a.bathrooms <> b.bathrooms AND abs(a.bathrooms - b.bathrooms) <= 0.5)
                    OR (a.sqft IS NOT NULL AND b.sqft IS NOT NULL AND a.sqft <> b.sqft)) AS d_match
    FROM nd_base a
    JOIN nd_base b ON b.municipality = a.municipality AND b.barrio = a.barrio
                  AND b.property_type_n = a.property_type_n AND b.bedrooms = a.bedrooms
                  AND a.id < b.id
),
nd_pairs AS (
    SELECT a_id, b_id, dist_m,
           CASE WHEN dist_m IS NULL THEN 'B'
                WHEN dist_m <= 25   THEN 'A'
                WHEN dist_m <= 100  THEN 'C' END AS tier
    FROM nd_joined WHERE abc_match
    UNION ALL
    SELECT a_id, b_id, dist_m, 'D' FROM nd_joined WHERE d_match
)
-- END near_duplicates PAIRS
SELECT l.id, l.price, l.bedrooms, l.bathrooms, l.duplicate_group_id IS NOT NULL AS in_dedup_group,
       l.is_primary_in_group,
       (SELECT string_agg(p.tier || ' with ' || CASE WHEN p.a_id = l.id THEN p.b_id ELSE p.a_id END
                          || coalesce(' at ' || round(p.dist_m::numeric) || ' m', ''), '; ')
        FROM nd_pairs p WHERE p.tier IS NOT NULL AND l.id IN (p.a_id, p.b_id)) AS candidate_pairs
FROM listings l
WHERE l.municipality_normalized = 'Bayamón' AND l.barrio ILIKE 'Sierra Bayamon%' AND l.price = 160000
  AND (l.is_primary_in_group IS DISTINCT FROM FALSE)
ORDER BY l.id;

-- 3. Up to 20 random pairs per tier, for review by eye
WITH
-- BEGIN near_duplicates PAIRS
nd_base AS (
    SELECT l.id, l.municipality_normalized AS municipality,
           coalesce(bc.canonical_name, l.barrio) AS barrio,
           v.property_type_n, l.bedrooms, l.bathrooms, l.sqft, l.price,
           l.geom::geography AS geog, l.scraped_at, l.title
    FROM v_market_unified v
    JOIN listings l ON l.id::text = v.id
    LEFT JOIN barrio_canonical bc
           ON bc.municipality = l.municipality_normalized AND bc.raw_name = l.barrio
    WHERE v.listing_type = 'sale'
      AND v.property_type_n IN ('casa', 'apartamento')
      AND v.price BETWEEN 20000 AND 2400000
      AND l.is_primary_in_group IS DISTINCT FROM FALSE
),
nd_joined AS (
    SELECT a.id AS a_id, b.id AS b_id,
           ST_Distance(a.geog, b.geog) AS dist_m,
           a.bathrooms = b.bathrooms
               AND abs(a.price - b.price) <= 0.02 * greatest(a.price, b.price) AS abc_match,
           a.price = b.price
               AND ((a.bathrooms <> b.bathrooms AND abs(a.bathrooms - b.bathrooms) <= 0.5)
                    OR (a.sqft IS NOT NULL AND b.sqft IS NOT NULL AND a.sqft <> b.sqft)) AS d_match
    FROM nd_base a
    JOIN nd_base b ON b.municipality = a.municipality AND b.barrio = a.barrio
                  AND b.property_type_n = a.property_type_n AND b.bedrooms = a.bedrooms
                  AND a.id < b.id
),
nd_pairs AS (
    SELECT a_id, b_id, dist_m,
           CASE WHEN dist_m IS NULL THEN 'B'
                WHEN dist_m <= 25   THEN 'A'
                WHEN dist_m <= 100  THEN 'C' END AS tier
    FROM nd_joined WHERE abc_match
    UNION ALL
    SELECT a_id, b_id, dist_m, 'D' FROM nd_joined WHERE d_match
)
-- END near_duplicates PAIRS
,
sampled AS (
    SELECT *, row_number() OVER (PARTITION BY tier ORDER BY random()) AS rn
    FROM nd_pairs WHERE tier IS NOT NULL
)
SELECT s.tier, s.rn,
       left(a.title, 45) AS title_a, left(b.title, 45) AS title_b,
       a.price AS price_a, b.price AS price_b,
       a.bedrooms || '/' || a.bathrooms || coalesce(' ' || a.sqft || 'sf', '') AS bb_a,
       b.bedrooms || '/' || b.bathrooms || coalesce(' ' || b.sqft || 'sf', '') AS bb_b,
       round(s.dist_m::numeric) AS dist_m,
       a.scraped_at::date AS scraped_a, b.scraped_at::date AS scraped_b
FROM sampled s
JOIN nd_base a ON a.id = s.a_id
JOIN nd_base b ON b.id = s.b_id
WHERE s.rn <= 20
ORDER BY s.tier, s.rn;

-- 4. Sensitivity (not for publication): island headline if each tier A
--    pair were collapsed to one row (the later-scraped member dropped)
WITH
-- BEGIN near_duplicates PAIRS
nd_base AS (
    SELECT l.id, l.municipality_normalized AS municipality,
           coalesce(bc.canonical_name, l.barrio) AS barrio,
           v.property_type_n, l.bedrooms, l.bathrooms, l.sqft, l.price,
           l.geom::geography AS geog, l.scraped_at, l.title
    FROM v_market_unified v
    JOIN listings l ON l.id::text = v.id
    LEFT JOIN barrio_canonical bc
           ON bc.municipality = l.municipality_normalized AND bc.raw_name = l.barrio
    WHERE v.listing_type = 'sale'
      AND v.property_type_n IN ('casa', 'apartamento')
      AND v.price BETWEEN 20000 AND 2400000
      AND l.is_primary_in_group IS DISTINCT FROM FALSE
),
nd_joined AS (
    SELECT a.id AS a_id, b.id AS b_id,
           ST_Distance(a.geog, b.geog) AS dist_m,
           a.bathrooms = b.bathrooms
               AND abs(a.price - b.price) <= 0.02 * greatest(a.price, b.price) AS abc_match,
           a.price = b.price
               AND ((a.bathrooms <> b.bathrooms AND abs(a.bathrooms - b.bathrooms) <= 0.5)
                    OR (a.sqft IS NOT NULL AND b.sqft IS NOT NULL AND a.sqft <> b.sqft)) AS d_match
    FROM nd_base a
    JOIN nd_base b ON b.municipality = a.municipality AND b.barrio = a.barrio
                  AND b.property_type_n = a.property_type_n AND b.bedrooms = a.bedrooms
                  AND a.id < b.id
),
nd_pairs AS (
    SELECT a_id, b_id, dist_m,
           CASE WHEN dist_m IS NULL THEN 'B'
                WHEN dist_m <= 25   THEN 'A'
                WHEN dist_m <= 100  THEN 'C' END AS tier
    FROM nd_joined WHERE abc_match
    UNION ALL
    SELECT a_id, b_id, dist_m, 'D' FROM nd_joined WHERE d_match
)
-- END near_duplicates PAIRS
,
dropped AS (
    SELECT DISTINCT CASE WHEN (a.scraped_at, a.id) > (b.scraped_at, b.id) THEN a.id ELSE b.id END AS id
    FROM nd_pairs p JOIN nd_base a ON a.id = p.a_id JOIN nd_base b ON b.id = p.b_id
    WHERE p.tier = 'A'
),
k AS (
    SELECT (0.07 / 12) * power(1 + 0.07 / 12, 360) / (power(1 + 0.07 / 12, 360) - 1) AS pmt_factor
),
scenarios AS (
    SELECT 'published (variant 3)' AS scenario, v.price, v.median_income
    FROM nd_base b JOIN v_market_unified v ON v.id = b.id::text
    UNION ALL
    SELECT 'tier A collapsed', v.price, v.median_income
    FROM nd_base b JOIN v_market_unified v ON v.id = b.id::text
    WHERE b.id NOT IN (SELECT id FROM dropped)
),
agg AS (
    SELECT scenario, COUNT(*) AS n,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY price))::numeric AS median_price,
           AVG(median_income) AS avg_median_income
    FROM scenarios GROUP BY scenario
)
SELECT scenario, n, median_price, round(avg_median_income) AS avg_median_income,
       round(100 * median_price * 0.95 * pmt_factor / (avg_median_income / 12), 1) AS pct_of_income
FROM agg, k
ORDER BY scenario DESC;
