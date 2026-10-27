-- ============================================================================
-- Deduplication — run record and invariants (SELECT only)
--
-- pipeline/deduplication.py was run against the live DB on 2026-10-22
-- (after migration 006). Expected as of that run: 348 groups, 875 rows in
-- groups, 348 primaries, 527 excluded duplicates, 12,548 listings (nothing
-- deleted), 5,723 listings (45.6%) without bedrooms/bathrooms/property_type
-- and therefore not checked. Every invariant row below should read "ok".
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/dedup_checks.sql
-- ============================================================================

SET default_transaction_read_only = on;

-- 1. Counts
SELECT 'listings rows'                    AS metric, COUNT(*) AS value FROM listings
UNION ALL SELECT 'duplicate groups',               COUNT(*) FROM listing_duplicate_groups
UNION ALL SELECT 'rows in groups',                 COUNT(*) FROM listings WHERE duplicate_group_id IS NOT NULL
UNION ALL SELECT 'primaries',                      COUNT(*) FROM listings WHERE is_primary_in_group
UNION ALL SELECT 'excluded duplicates',            COUNT(*) FROM listings WHERE is_primary_in_group = FALSE
UNION ALL SELECT 'not checked (missing dedup key)', COUNT(*) FROM listings
          WHERE bedrooms IS NULL OR bathrooms IS NULL OR property_type IS NULL;

-- 2. Invariants
SELECT 'every group has exactly one primary' AS invariant,
       CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE COUNT(*) || ' groups fail' END AS result
FROM (SELECT duplicate_group_id FROM listings WHERE duplicate_group_id IS NOT NULL
      GROUP BY 1 HAVING COUNT(*) FILTER (WHERE is_primary_in_group) <> 1) g
UNION ALL
SELECT 'member_count matches flagged members',
       CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE COUNT(*) || ' groups fail' END
FROM listing_duplicate_groups g
WHERE member_count <> (SELECT COUNT(*) FROM listings l WHERE l.duplicate_group_id = g.group_id)
UNION ALL
SELECT 'group pointer and primary flag set together',
       CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE COUNT(*) || ' rows fail' END
FROM listings WHERE (duplicate_group_id IS NULL) <> (is_primary_in_group IS NULL)
UNION ALL
SELECT 'primary is the module''s first-ranked row',
       CASE WHEN COUNT(*) = 0 THEN 'ok' ELSE COUNT(*) || ' groups fail' END
FROM (
    SELECT (array_agg(id ORDER BY (detail_status = 'ok') DESC,
                      (seller_name IS NOT NULL AND seller_name != 'Unknown') DESC,
                      (agency_name IS NOT NULL AND agency_name != 'Unknown') DESC,
                      scraped_at ASC, id ASC))[1] AS best,
           MAX(id) FILTER (WHERE is_primary_in_group) AS prim
    FROM listings WHERE duplicate_group_id IS NOT NULL
    GROUP BY duplicate_group_id
) x
WHERE best <> prim;
