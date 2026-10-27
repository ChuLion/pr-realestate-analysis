-- ============================================================================
-- Data Health ledger (SELECT only) — one row per known data issue.
--
-- Columns: issue, description, rows_affected, base_rows, pct,
-- blocks_publishing ('no' | 'caveat' | 'yes' + scope), source_check
-- (the query or migration that proves it). Counts are live; two are
-- CURRENT_DATE-relative (noted in the row). The near_duplicates PAIRS
-- block is identical to analysis/quality/near_duplicates.sql, and the
-- barrio_variants LOOSE block to analysis/quality/barrio_variants.sql.
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/conflict_ledger.sql
-- ============================================================================

SET default_transaction_read_only = on;

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
,
nd_ids AS (
    SELECT tier, a_id AS id FROM nd_pairs UNION SELECT tier, b_id FROM nd_pairs
),
lost_buy_vs_rent AS (
    -- Municipalities that pass v_buy_vs_rent's ≥5 sale / ≥5 rental gate
    -- without migration 010's is_active filter, but fail it with the filter
    SELECT r.municipality_normalized
    FROM rentals r
    WHERE r.price_monthly BETWEEN 300 AND 50000
    GROUP BY r.municipality_normalized
    HAVING COUNT(*) >= 5
       AND COUNT(*) FILTER (WHERE r.is_active IS DISTINCT FROM FALSE) < 5
       AND (SELECT COUNT(*) FROM listings l
            WHERE l.municipality_normalized = r.municipality_normalized
              AND l.price BETWEEN 20000 AND 15000000
              AND l.is_active IS DISTINCT FROM FALSE) >= 5
),
barrio_variants AS (
    -- Listings whose barrio has another spelling in the same municipality
    -- (differs only by case, accents or spacing)
    SELECT municipality_normalized, lower(unaccent(regexp_replace(trim(barrio), '\s+', ' ', 'g'))) AS key,
           COUNT(DISTINCT barrio) AS spellings, COUNT(*) AS n
    FROM listings
    WHERE barrio IS NOT NULL
    GROUP BY 1, 2
),
loc AS (
    SELECT CASE WHEN property_type ~* 'comerc' THEN 'other'
                WHEN property_type ~* '(aparta|walk)' OR lower(property_type) = 'townhouse' THEN 'apartamento'
                WHEN property_type ~* 'casa' THEN 'casa'
                ELSE 'other' END AS type_group,
           geom
    FROM listings
),
pins AS (
    SELECT municipality_normalized, barrio, COUNT(*) AS n, COUNT(DISTINCT geom) AS points
    FROM listings WHERE geom IS NOT NULL GROUP BY 1, 2
),
names AS (
    SELECT DISTINCT municipality_normalized AS municipality, barrio FROM listings
    UNION SELECT municipality_normalized, barrio FROM rentals
    UNION SELECT municipality_normalized, barrio FROM listings_sold
    UNION SELECT municipality_normalized, barrio FROM barrio_crim_samples
),
truncated AS (
    SELECT DISTINCT a.municipality, a.barrio
    FROM names a
    JOIN names b ON b.municipality = a.municipality
                AND length(a.barrio) = 30 AND length(b.barrio) > 30
                AND left(lower(unaccent(b.barrio)), 30) = lower(unaccent(a.barrio))
),
casa_apto AS (
    SELECT COUNT(*) AS total,
           COUNT(*) FILTER (WHERE bedrooms IS NULL OR bathrooms IS NULL) AS missing_key
    FROM listings
    WHERE property_type ~* '(casa|aparta|walk|townhouse)'
),
ledger (issue, description, rows_affected, base_rows, blocks_publishing, source_check) AS (
    SELECT 'duplicate groups',
           'Exact-key duplicate groups found by dedup (2026-10-22)',
           (SELECT COUNT(*) FROM listing_duplicate_groups),
           (SELECT COUNT(*) FROM listings),
           'no', 'analysis/quality/dedup_checks.sql'
    UNION ALL
    SELECT 'duplicate rows (in a group)', 'Listings that belong to a duplicate group',
           (SELECT COUNT(*) FROM listings WHERE duplicate_group_id IS NOT NULL),
           (SELECT COUNT(*) FROM listings), 'no', 'analysis/quality/dedup_checks.sql'
    UNION ALL
    SELECT 'duplicate excess', 'Non-primary duplicates; excluded from published figures (variant 3)',
           (SELECT COUNT(*) FROM listings WHERE is_primary_in_group = FALSE),
           (SELECT COUNT(*) FROM listings), 'no', 'analysis/quality/dedup_checks.sql'
    UNION ALL
    SELECT 'missing dedup key (all listings)',
           'No bedrooms, bathrooms or property_type: dedup could not check them',
           (SELECT COUNT(*) FROM listings WHERE bedrooms IS NULL OR bathrooms IS NULL OR property_type IS NULL),
           (SELECT COUNT(*) FROM listings), 'caveat', 'analysis/quality/dedup_checks.sql'
    UNION ALL
    SELECT 'missing dedup key (casa/apartamento)',
           'Casa/apartamento listings without bedrooms or bathrooms: possible undetected duplicates in the affordability base',
           (SELECT missing_key FROM casa_apto), (SELECT total FROM casa_apto),
           'caveat', 'this file'
    UNION ALL
    SELECT 'active-and-sold (corrected)',
           'Listing IDs also in listings_sold, set is_active = FALSE by migration 007. Still not FALSE: '
           || (SELECT COUNT(*) FROM listings l WHERE l.is_active IS DISTINCT FROM FALSE
               AND EXISTS (SELECT 1 FROM listings_sold s WHERE s.id = l.id)),
           (SELECT COUNT(*) FROM listings l WHERE l.is_active = FALSE
            AND EXISTS (SELECT 1 FROM listings_sold s WHERE s.id = l.id)),
           (SELECT COUNT(*) FROM listings), 'no', 'migration_007 verify'
    UNION ALL
    SELECT 'sold_price = 0', 'Remaining zero sold prices (migration 007 set 691 to NULL)',
           (SELECT COUNT(*) FROM listings_sold WHERE sold_price = 0),
           (SELECT COUNT(*) FROM listings_sold), 'no', 'migration_007 verify'
    UNION ALL
    SELECT 'sold_price unknown (NULL)', 'Sold records without a price, incl. the 691 former zeros',
           (SELECT COUNT(*) FROM listings_sold WHERE sold_price IS NULL),
           (SELECT COUNT(*) FROM listings_sold), 'caveat', 'migration_007 verify'
    UNION ALL
    SELECT 'sold_date nulled (tier 1)', 'Impossible sold dates (>180 days future or before 2000) set to NULL by migration 004',
           (SELECT COUNT(*) FROM listings_sold WHERE sold_date IS NULL AND date_future_flag),
           (SELECT COUNT(*) FROM listings_sold), 'no', 'migration_004 verify'
    UNION ALL
    SELECT 'sold_date future (tier 2)', 'Sold dates after today, kept by design (ADR 001). CURRENT_DATE-relative',
           (SELECT COUNT(*) FROM listings_sold WHERE sold_date > CURRENT_DATE),
           (SELECT COUNT(*) FROM listings_sold), 'caveat', 'migration_004 verify'
    UNION ALL
    SELECT 'status: reliable values',
           'listings.status rows set. The old regex matched "Reportar"; reset to NULL in CP2. No status figure is publishable',
           (SELECT COUNT(*) FROM listings WHERE status IS NOT NULL),
           (SELECT COUNT(*) FROM listings), 'yes (any status/repo figure)', 'analysis/quality/readme_numbers.sql'
    UNION ALL
    SELECT 'distress_text_flag set',
           'Explicit distress wording in title+description (12 before boilerplate strip, 6 after, 44 with hud_owned/homepath): '
           || (SELECT string_agg(distress_text_flag || ' ' || n, ', ' ORDER BY n DESC)
               FROM (SELECT distress_text_flag, COUNT(*) AS n FROM listings
                     WHERE distress_text_flag IS NOT NULL GROUP BY 1) f),
           (SELECT COUNT(*) FROM listings WHERE distress_text_flag IS NOT NULL),
           (SELECT COUNT(*) FROM listings), 'caveat', 'analysis/quality/distress_text_flag.sql'
    UNION ALL
    SELECT 'barrio spelling variants',
           'Listings whose barrio has another spelling in the same municipality (case/accent/spacing only); groups: '
           || (SELECT COUNT(*) FROM barrio_variants WHERE spellings > 1),
           (SELECT COALESCE(SUM(n), 0) FROM barrio_variants WHERE spellings > 1),
           (SELECT COUNT(*) FROM listings WHERE barrio IS NOT NULL), 'caveat', 'this file'
    UNION ALL
    SELECT 'barrio spelling variants, all sources (HIGH)',
           'Raw barrio spellings that differ from their canonical name only by case/accents/whitespace, within municipality, across listings, sold, rentals and CRIM samples; mapped in barrio_canonical (migration 011), not applied to any view. REVIEW groups: analysis/quality/barrio_variants.sql',
           (SELECT COUNT(*) FROM barrio_canonical WHERE rule <> 'canonical'),
           (SELECT COUNT(*) FROM (SELECT municipality_normalized, barrio FROM listings
                                  UNION SELECT municipality_normalized, barrio FROM listings_sold
                                  UNION SELECT municipality_normalized, barrio FROM rentals
                                  UNION SELECT municipality_normalized, barrio FROM barrio_crim_samples) u),
           'caveat (barrio-level joins)', 'analysis/quality/barrio_variants.sql'
    UNION ALL
    SELECT 'CRIM parcel in >1 barrio sample',
           'Same num_catastro sampled for more than one barrio: tax-gap barrio figures share parcels',
           (SELECT COUNT(*) FROM (SELECT num_catastro FROM barrio_crim_sample_parcels GROUP BY 1
                                  HAVING COUNT(DISTINCT (municipality_normalized, barrio)) > 1) p),
           (SELECT COUNT(DISTINCT num_catastro) FROM barrio_crim_sample_parcels),
           'yes (tax-gap figures)', 'analysis/quality/readme_numbers.sql'
    UNION ALL
    SELECT 'CRIM parcel in >1 municipality sample',
           'Same num_catastro sampled under more than one municipality',
           (SELECT COUNT(*) FROM (SELECT num_catastro FROM barrio_crim_sample_parcels GROUP BY 1
                                  HAVING COUNT(DISTINCT municipality_normalized) > 1) p),
           (SELECT COUNT(DISTINCT num_catastro) FROM barrio_crim_sample_parcels),
           'yes (tax-gap figures)', 'this file'
    UNION ALL
    SELECT 'grid rows from the Dorado box (F9)',
           'island_grid_parcels sampled 2026-06-11 21:09–21:42 while METRO_BOUNDS held the Dorado box: over-samples Dorado/Vega Alta',
           (SELECT COUNT(*) FROM island_grid_parcels
            WHERE sampled_at >= '2026-06-11 21:09' AND sampled_at < '2026-06-11 21:43'),
           (SELECT COUNT(*) FROM island_grid_parcels), 'caveat (grid-based figures)', 'SPRINT.md F9'
    UNION ALL
    SELECT 'is_active NULL = unconfirmed (listings)',
           'Not seen in 30 days at migration 003; neither confirmed active nor gone. Kept in v_market_unified',
           (SELECT COUNT(*) FROM listings WHERE is_active IS NULL),
           (SELECT COUNT(*) FROM listings), 'caveat (label "snapshot Mar–Jun 2026")', 'migration_003 / 010'
    UNION ALL
    SELECT 'is_active NULL = unconfirmed (rentals)',
           'As above, for rentals',
           (SELECT COUNT(*) FROM rentals WHERE is_active IS NULL),
           (SELECT COUNT(*) FROM rentals), 'caveat (label "snapshot Mar–Jun 2026")', 'migration_003 / 010'
    UNION ALL
    SELECT 'v_buy_vs_rent municipalities lost',
           'Fall below the view''s ≥5-rental gate once migration 010 drops confirmed-gone rentals: '
           || (SELECT string_agg(municipality_normalized, ', ' ORDER BY municipality_normalized) FROM lost_buy_vs_rent),
           (SELECT COUNT(*) FROM lost_buy_vs_rent),
           (SELECT COUNT(*) FROM lost_buy_vs_rent) + (SELECT COUNT(*) FROM v_buy_vs_rent),
           'caveat (buy-vs-rent figures)', 'migration_010; this file'
    UNION ALL
    SELECT 'near-duplicate candidates, tier A',
           'Candidates for review, not applied: same municipality, canonical barrio, type, beds, baths; price within 2%; ≤ 25 m (all at 0 m: shared pins). Pairs: '
           || (SELECT COUNT(*) FROM nd_pairs WHERE tier = 'A'),
           (SELECT COUNT(*) FROM nd_ids WHERE tier = 'A'),
           (SELECT COUNT(*) FROM nd_base), 'no (sensitivity only)', 'analysis/quality/near_duplicates.sql'
    UNION ALL
    SELECT 'near-duplicate candidates, tier B',
           'Candidates for review, not applied: as A, but coordinates missing on at least one side. Pairs: '
           || (SELECT COUNT(*) FROM nd_pairs WHERE tier = 'B'),
           (SELECT COUNT(*) FROM nd_ids WHERE tier = 'B'),
           (SELECT COUNT(*) FROM nd_base), 'no (sensitivity only)', 'analysis/quality/near_duplicates.sql'
    UNION ALL
    SELECT 'near-duplicate candidates, tier C',
           'Candidates for review, not applied: as A, but 25–100 m apart. Pairs: '
           || (SELECT COUNT(*) FROM nd_pairs WHERE tier = 'C'),
           (SELECT COUNT(*) FROM nd_ids WHERE tier = 'C'),
           (SELECT COUNT(*) FROM nd_base), 'no (sensitivity only)', 'analysis/quality/near_duplicates.sql'
    UNION ALL
    SELECT 'near-duplicate candidates, tier D',
           'Candidates for review, not applied: same municipality, canonical barrio, type, beds and exact price; baths differ by ≤ 0.5 or sqft differs. Pairs: '
           || (SELECT COUNT(*) FROM nd_pairs WHERE tier = 'D'),
           (SELECT COUNT(*) FROM nd_ids WHERE tier = 'D'),
           (SELECT COUNT(*) FROM nd_base), 'no (sensitivity only)', 'analysis/quality/near_duplicates.sql'
    UNION ALL
    SELECT 'listings with an address',
           'listings and rentals have no address column; no address is stored, so none can be published or matched',
           0, (SELECT COUNT(*) FROM listings), 'yes (any address-level claim)', 'information_schema.columns'
    UNION ALL
    SELECT 'listings with coordinates (casa)', 'Listings of this type with lat/lon (barrio-level pins, see next rows)',
           (SELECT COUNT(geom) FROM loc WHERE type_group = 'casa'), (SELECT COUNT(*) FROM loc WHERE type_group = 'casa'),
           'no', 'this file'
    UNION ALL
    SELECT 'listings with neither address nor coordinates (casa)', 'No address column exists, so this is listings without lat/lon',
           (SELECT COUNT(*) - COUNT(geom) FROM loc WHERE type_group = 'casa'), (SELECT COUNT(*) FROM loc WHERE type_group = 'casa'),
           'caveat (map layers)', 'this file'
    UNION ALL
    SELECT 'listings with coordinates (apartamento)', 'Listings of this type with lat/lon (barrio-level pins, see next rows)',
           (SELECT COUNT(geom) FROM loc WHERE type_group = 'apartamento'), (SELECT COUNT(*) FROM loc WHERE type_group = 'apartamento'),
           'no', 'this file'
    UNION ALL
    SELECT 'listings with neither address nor coordinates (apartamento)', 'No address column exists, so this is listings without lat/lon',
           (SELECT COUNT(*) - COUNT(geom) FROM loc WHERE type_group = 'apartamento'), (SELECT COUNT(*) FROM loc WHERE type_group = 'apartamento'),
           'caveat (map layers)', 'this file'
    UNION ALL
    SELECT 'listings with coordinates (other)', 'Listings of this type with lat/lon (barrio-level pins, see next rows)',
           (SELECT COUNT(geom) FROM loc WHERE type_group = 'other'), (SELECT COUNT(*) FROM loc WHERE type_group = 'other'),
           'no', 'this file'
    UNION ALL
    SELECT 'listings with neither address nor coordinates (other)', 'No address column exists, so this is listings without lat/lon',
           (SELECT COUNT(*) - COUNT(geom) FROM loc WHERE type_group = 'other'), (SELECT COUNT(*) FROM loc WHERE type_group = 'other'),
           'caveat (map layers)', 'this file'
    UNION ALL
    SELECT 'coordinates are barrio-level pins',
           'Listings with coordinates share few points: distinct points '
           || (SELECT COUNT(DISTINCT geom) FROM listings)
           || ', max listings on one point '
           || (SELECT MAX(c) FROM (SELECT COUNT(*) AS c FROM listings WHERE geom IS NOT NULL GROUP BY geom) x)
           || ', barrios with 2+ located listings on a single point '
           || (SELECT COUNT(*) FILTER (WHERE points = 1) FROM pins WHERE n >= 2) || ' of '
           || (SELECT COUNT(*) FROM pins WHERE n >= 2)
           || '. Distance cannot separate properties within a barrio',
           (SELECT COUNT(geom) FROM listings), (SELECT COUNT(*) FROM listings),
           'yes (any sub-barrio location claim)', 'this file; analysis/quality/near_duplicates.sql'
    UNION ALL
    SELECT 'barrio names truncated at 30 characters',
           'listings/rentals store at most 30 characters (max: listings '
           || (SELECT MAX(length(barrio)) FROM listings) || ', rentals ' || (SELECT MAX(length(barrio)) FROM rentals)
           || '; sold ' || (SELECT MAX(length(barrio)) FROM listings_sold) || ', CRIM samples '
           || (SELECT MAX(length(barrio)) FROM barrio_crim_samples)
           || '). Rows here = listing+rental rows at exactly 30. Truncated names matching one longer name: '
           || (SELECT COUNT(*) FROM truncated),
           (SELECT COUNT(*) FROM listings WHERE length(barrio) = 30) + (SELECT COUNT(*) FROM rentals WHERE length(barrio) = 30),
           (SELECT COUNT(*) FROM listings) + (SELECT COUNT(*) FROM rentals),
           'caveat (barrio-level joins)', 'analysis/quality/barrio_variants.sql query 4'
    UNION ALL
    SELECT 'barrio REVIEW groups: article/abbreviation variants',
           'Flagged for review, not merged: same municipality, names differ by de/del/la/las/los/el, abbreviations or punctuation',
           (SELECT COUNT(*) FROM (SELECT municipality, loose_key FROM l GROUP BY 1, 2 HAVING COUNT(DISTINCT match_key) > 1) g),
           (SELECT COUNT(*) FROM (SELECT DISTINCT municipality, match_key FROM l) d),
           'caveat (barrio-level joins)', 'analysis/quality/barrio_variants.sql query 3'
    UNION ALL
    SELECT 'barrio REVIEW groups: truncated names',
           'Flagged for review, not merged: a 30-character listing/rental name is the prefix of one longer name',
           (SELECT COUNT(*) FROM truncated),
           (SELECT COUNT(*) FROM names),
           'caveat (barrio-level joins)', 'analysis/quality/barrio_variants.sql query 4'
    UNION ALL
    SELECT 'duplicate-spelling barrios within barrio_crim_samples',
           'Same municipality and barrio sampled twice under spellings that differ only by case/accents/whitespace (e.g. "Cupey " and "Cupey")',
           (SELECT COUNT(*) FROM (SELECT municipality, match_key FROM k WHERE src = 'C'
                                  GROUP BY 1, 2 HAVING COUNT(DISTINCT barrio) > 1) g),
           (SELECT COUNT(*) FROM barrio_crim_samples),
           'yes (tax-gap figures)', 'analysis/quality/barrio_variants.sql query 2'
    UNION ALL
    SELECT 'listings carry no parcel id',
           'listings has no num_catastro or other parcel column; no listing is linked to a CRIM parcel. No match rate is estimated',
           (SELECT COUNT(*) FROM listings),
           (SELECT COUNT(*) FROM listings), 'yes (any listing-to-parcel claim)', 'information_schema.columns'
),
display (issue, template) AS (
    -- Plain-English line per issue for the dashboard (max 120 characters);
    -- {n}, {base}, {pct} are filled from the row
    VALUES
    ('duplicate groups',
     '{n} sets of identical listings (same house posted more than once) were found.'),
    ('duplicate rows (in a group)',
     '{n} listings belong to a set of identical listings.'),
    ('duplicate excess',
     '{n} repeat copies of listings are excluded from published figures.'),
    ('missing dedup key (all listings)',
     '{pct}% of listings lack beds, baths or type, so duplicates among them can''t be checked.'),
    ('missing dedup key (casa/apartamento)',
     '{n} of {base} houses and apartments lack beds or baths; duplicates among them can''t be checked.'),
    ('active-and-sold (corrected)',
     '{n} listings that had already sold were removed from the for-sale count.'),
    ('sold_price = 0',
     'No sold record has a $0 price; the {base} sold records were cleaned.'),
    ('sold_price unknown (NULL)',
     '{n} sold records have no price and are left out of sold-price figures.'),
    ('sold_date nulled (tier 1)',
     '{n} impossible sale dates (far future or before 2000) were blanked.'),
    ('sold_date future (tier 2)',
     '{n} sold records carry a sale date slightly in the future; kept as posted.'),
    ('status: reliable values',
     'No reliable sale-status label exists; no repossession share is published.'),
    ('distress_text_flag set',
     '{n} listings say in their own text they are bank-, HUD- or lender-owned or repossessed.'),
    ('barrio spelling variants',
     '{n} listings use a barrio name that differs from another only by spacing or case.'),
    ('barrio spelling variants, all sources (HIGH)',
     '{n} barrio spellings differ only by spacing or case; mapped to one name, not yet applied.'),
    ('CRIM parcel in >1 barrio sample',
     '{n} tax parcels were sampled for more than one barrio, so barrio tax figures overlap.'),
    ('CRIM parcel in >1 municipality sample',
     '{n} tax parcels were sampled under more than one municipality.'),
    ('grid rows from the Dorado box (F9)',
     '{n} tax-grid samples over-represent Dorado and Vega Alta (sampling error, kept).'),
    ('is_active NULL = unconfirmed (listings)',
     '{pct}% of for-sale listings were not re-checked after the snapshot (Mar–Jun 2026).'),
    ('is_active NULL = unconfirmed (rentals)',
     '{pct}% of rentals were not re-checked after the snapshot (Mar–Jun 2026).'),
    ('v_buy_vs_rent municipalities lost',
     '{n} municipalities have too few current rentals for a buy-vs-rent comparison.'),
    ('near-duplicate candidates, tier A',
     '{n} listings look like possible repeats (same area, size, price within 2%); not removed.'),
    ('near-duplicate candidates, tier B',
     '{n} listings look like possible repeats but lack a map location; not removed.'),
    ('near-duplicate candidates, tier C',
     'No possible repeats were found 25–100 m apart.'),
    ('near-duplicate candidates, tier D',
     '{n} listings share a price and area but differ slightly in baths or size; not removed.'),
    ('listings with an address',
     'Listings carry no street address; no address-level result is possible.'),
    ('listings with coordinates (casa)',
     '{pct}% of houses have a map location (neighbourhood-level, not the exact house).'),
    ('listings with neither address nor coordinates (casa)',
     '{n} houses have no map location.'),
    ('listings with coordinates (apartamento)',
     '{pct}% of apartments have a map location (neighbourhood-level, not the exact unit).'),
    ('listings with neither address nor coordinates (apartamento)',
     '{n} apartments have no map location.'),
    ('listings with coordinates (other)',
     '{pct}% of other listings (land and other non-residential) have a map location.'),
    ('listings with neither address nor coordinates (other)',
     '{n} other listings (land and other non-residential) have no map location.'),
    ('coordinates are barrio-level pins',
     'Map locations are one shared pin per barrio, not the exact property.'),
    ('barrio names truncated at 30 characters',
     '{n} listing and rental barrio names are exactly 30 characters long, which looks like a field limit.'),
    ('barrio REVIEW groups: article/abbreviation variants',
     '{n} barrio name pairs differ by words like "de" or "la"; flagged for review, not merged.'),
    ('barrio REVIEW groups: truncated names',
     '{n} cut-off barrio names likely match a longer name; flagged for review, not merged.'),
    ('duplicate-spelling barrios within barrio_crim_samples',
     '{n} barrios were tax-sampled twice under slightly different spellings.'),
    ('listings carry no parcel id',
     'Listings are not linked to tax parcels; no listing-to-parcel comparison is made.')
)
SELECT l.issue, l.description, l.rows_affected, l.base_rows,
       round(100.0 * l.rows_affected / NULLIF(l.base_rows, 0), 1) AS pct,
       l.blocks_publishing, l.source_check,
       replace(replace(replace(d.template,
           '{n}', to_char(l.rows_affected, 'FM999,999,999')),
           '{base}', to_char(l.base_rows, 'FM999,999,999')),
           '{pct}', round(100.0 * l.rows_affected / NULLIF(l.base_rows, 0), 1)::text) AS display_text
FROM ledger l
LEFT JOIN display d USING (issue);
