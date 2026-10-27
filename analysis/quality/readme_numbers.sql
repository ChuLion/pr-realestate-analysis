-- ============================================================================
-- README numbers — reproducing queries (SELECT only)
--
-- Every count quoted in README.md's "Current Data Coverage" and
-- "Notes on Data Quality" comes from one of the rows below.
-- Published findings are NOT here — they belong in analysis/claims/.
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/readme_numbers.sql
-- ============================================================================

SET default_transaction_read_only = on;

-- Coverage table
SELECT 'listings rows'               AS metric, COUNT(*)::text AS value FROM listings
UNION ALL SELECT 'rentals rows',               COUNT(*)::text FROM rentals
UNION ALL SELECT 'listings_sold rows',         COUNT(*)::text FROM listings_sold
UNION ALL SELECT 'island_grid_parcels rows',   COUNT(*)::text FROM island_grid_parcels
UNION ALL SELECT 'barrio_coords rows',         COUNT(*)::text FROM barrio_coords
UNION ALL SELECT 'census_income municipalities', COUNT(DISTINCT municipality_normalized)::text FROM census_income
UNION ALL SELECT 'crim_valuations rows',       COUNT(*)::text FROM crim_valuations
UNION ALL SELECT 'last scraped_at (listings, rentals, listings_sold)',
                 GREATEST((SELECT max(scraped_at) FROM listings),
                          (SELECT max(scraped_at) FROM rentals),
                          (SELECT max(scraped_at) FROM listings_sold))::date::text;

-- Data quality notes
-- Share of listings without bedrooms, bathrooms or property_type
-- (outside dedup coverage)
SELECT round(100.0 * COUNT(*) FILTER (WHERE bedrooms IS NULL OR bathrooms IS NULL
                                       OR property_type IS NULL) / COUNT(*), 1)
       AS pct_outside_dedup_coverage
FROM listings;

-- CRIM sample spillover: parcels appearing in more than one barrio's sample
SELECT COUNT(*) AS parcels_in_multiple_barrio_samples
FROM (
    SELECT num_catastro
    FROM barrio_crim_sample_parcels
    GROUP BY num_catastro
    HAVING COUNT(DISTINCT (municipality_normalized, barrio)) > 1
) p;

-- Listings whose status is set (the column is unreliable — see README)
SELECT coalesce(status, '(null)') AS status, COUNT(*) FROM listings GROUP BY 1 ORDER BY 2 DESC;
