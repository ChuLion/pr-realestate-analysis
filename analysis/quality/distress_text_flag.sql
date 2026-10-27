-- ============================================================================
-- distress_text_flag — quality review (SELECT only)
--
-- Classifies listings by explicit bank-owned / distress wording in
-- title + description, for manual review before migration 009 writes the
-- same classification into listings.distress_text_flag.
--
-- Before matching, agent-inventory boilerplate is stripped ("nuestro
-- inventario …", "listado … reposeídas", "Pida nuestro …", "re venta y/o
-- reposeídas"): it advertises the broker's other listings, not this property.
-- Word-bounded on purpose. Not matched: financing boilerplate
-- ("precualificación bancaria", "financiar por banco"), "sin embargo"
-- (= "however"), reposicionamiento, report/reporte, repostería.
-- REO is case-sensitive (Spanish "reo" = prisoner). hud_owned matches only
-- ownership/auction phrasing ("propiedad de HUD", "subasta de HUD", HUD case
-- numbers); HUD as FHA lender or closing-cost helper is not matched.
-- homepath (Fannie Mae HomePath, lender-owned) is a separate class.
--
-- Every CASE and CLEAN block between the BEGIN/END markers must stay
-- identical, here and in migration_009 (tests/test_distress_text_flag_sql.py).
--
-- Run: psql -h localhost -d pr_realestate -f analysis/quality/distress_text_flag.sql
-- ============================================================================

SET default_transaction_read_only = on;
SELECT setseed(0.42);  -- reproducible samples

-- 1. Rows per class (first matching pattern wins)
WITH classified AS (
    SELECT
-- BEGIN distress_text_flag CASE
    CASE
        WHEN txt ~* '\mrepose(i|í|ie)d[ao]s?\M'           THEN 'reposeida'
        WHEN txt ~* '\mrepossess\w*'                     THEN 'repossessed'
        WHEN txt ~* '\mbank[- ]owned\M'                  THEN 'bank_owned'
        WHEN txt ~* '\mpropiedad(es)? del banco\M'       THEN 'propiedad_del_banco'
        WHEN txt ~* '\membargad[ao]s?\M'                 THEN 'embargada'
        WHEN txt ~* '\mejecuci[oó]n de hipoteca\M'       THEN 'ejecucion_de_hipoteca'
        WHEN txt ~  '\mREO\M'                            THEN 'reo'
        WHEN txt ~* '\mforeclos\w*'                      THEN 'foreclosure'
        WHEN txt ~* '\mpropiedad(es)? (de )?hud\M|\mhud[- ]owned\M|\mhud homes?\M|\msubasta de hud\M|\mhud (escoge|se reserva)\M|\m(hud #?|caso )501-\d{6}\M' THEN 'hud_owned'
        WHEN txt ~* '\mhome ?path\M'                   THEN 'homepath'
    END AS distress_text_flag
-- END distress_text_flag CASE
    FROM (SELECT
-- BEGIN distress_text_flag CLEAN
          regexp_replace(coalesce(title, '') || ' ' || coalesce(description, ''),
                         '(nuestros? inventarios?[^.;:!]*|listado[^.;:!]{0,40}repose(i|í|ie)d\w*|pida nuestro[^.;:!]*|re[ -]?venta (y|o) repose(i|í|ie)d\w*)',
                         ' ', 'gi') AS txt
-- END distress_text_flag CLEAN
          FROM listings) x
)
SELECT coalesce(distress_text_flag, '(none)') AS distress_text_flag, COUNT(*) AS total
FROM classified
GROUP BY 1
ORDER BY total DESC;

-- 2. Rows matching each pattern independently (a row can match several)
SELECT pattern, COUNT(*) AS rows_matching
FROM (SELECT
-- BEGIN distress_text_flag CLEAN
          regexp_replace(coalesce(title, '') || ' ' || coalesce(description, ''),
                         '(nuestros? inventarios?[^.;:!]*|listado[^.;:!]{0,40}repose(i|í|ie)d\w*|pida nuestro[^.;:!]*|re[ -]?venta (y|o) repose(i|í|ie)d\w*)',
                         ' ', 'gi') AS txt
-- END distress_text_flag CLEAN
      FROM listings) x
CROSS JOIN LATERAL (VALUES
    ('reposeida',             txt ~* '\mrepose(i|í|ie)d[ao]s?\M'),
    ('repossessed',           txt ~* '\mrepossess\w*'),
    ('bank_owned',            txt ~* '\mbank[- ]owned\M'),
    ('propiedad_del_banco',   txt ~* '\mpropiedad(es)? del banco\M'),
    ('embargada',             txt ~* '\membargad[ao]s?\M'),
    ('ejecucion_de_hipoteca', txt ~* '\mejecuci[oó]n de hipoteca\M'),
    ('reo',                   txt ~  '\mREO\M'),
    ('foreclosure',           txt ~* '\mforeclos\w*'),
    ('hud_owned',             txt ~* '\mpropiedad(es)? (de )?hud\M|\mhud[- ]owned\M|\mhud homes?\M|\msubasta de hud\M|\mhud (escoge|se reserva)\M|\m(hud #?|caso )501-\d{6}\M'),
    ('homepath',              txt ~* '\mhome ?path\M')
) p(pattern, hit)
WHERE hit
GROUP BY pattern
ORDER BY rows_matching DESC;

-- 3. Excluded terms (in the raw text): rows containing them, and how many are flagged anyway
WITH classified AS (
    SELECT raw,
-- BEGIN distress_text_flag CASE
    CASE
        WHEN txt ~* '\mrepose(i|í|ie)d[ao]s?\M'           THEN 'reposeida'
        WHEN txt ~* '\mrepossess\w*'                     THEN 'repossessed'
        WHEN txt ~* '\mbank[- ]owned\M'                  THEN 'bank_owned'
        WHEN txt ~* '\mpropiedad(es)? del banco\M'       THEN 'propiedad_del_banco'
        WHEN txt ~* '\membargad[ao]s?\M'                 THEN 'embargada'
        WHEN txt ~* '\mejecuci[oó]n de hipoteca\M'       THEN 'ejecucion_de_hipoteca'
        WHEN txt ~  '\mREO\M'                            THEN 'reo'
        WHEN txt ~* '\mforeclos\w*'                      THEN 'foreclosure'
        WHEN txt ~* '\mpropiedad(es)? (de )?hud\M|\mhud[- ]owned\M|\mhud homes?\M|\msubasta de hud\M|\mhud (escoge|se reserva)\M|\m(hud #?|caso )501-\d{6}\M' THEN 'hud_owned'
        WHEN txt ~* '\mhome ?path\M'                   THEN 'homepath'
    END AS distress_text_flag
-- END distress_text_flag CASE
    FROM (SELECT coalesce(title, '') || ' ' || coalesce(description, '') AS raw,
-- BEGIN distress_text_flag CLEAN
          regexp_replace(coalesce(title, '') || ' ' || coalesce(description, ''),
                         '(nuestros? inventarios?[^.;:!]*|listado[^.;:!]{0,40}repose(i|í|ie)d\w*|pida nuestro[^.;:!]*|re[ -]?venta (y|o) repose(i|í|ie)d\w*)',
                         ' ', 'gi') AS txt
-- END distress_text_flag CLEAN
          FROM listings) x
)
SELECT term, COUNT(*) AS rows_with_term,
       COUNT(*) FILTER (WHERE distress_text_flag IS NOT NULL) AS also_flagged
FROM classified
CROSS JOIN LATERAL (VALUES
    ('agent inventory phrasing',  raw ~* '(nuestros? inventarios?|listado[^.;:!]{0,40}repose(i|í|ie)d|pida nuestro|re[ -]?venta (y|o) repose(i|í|ie)d)'),
    ('precualificación bancaria', raw ~* 'pre-?cualificaci[oó]n bancaria'),
    ('financiar por banco',       raw ~* 'financia\w* (por|con) (el )?banco'),
    ('sin embargo',               raw ~* '\msin embargo\M'),
    ('reposicionamiento',         raw ~* '\mreposicion\w*'),
    ('report/reporte',            raw ~* '\mreport\w*'),
    ('repostería',                raw ~* '\mreposter\w*')
) e(term, hit)
WHERE hit
GROUP BY term
ORDER BY rows_with_term DESC;

-- 4. Up to 20 random rows per class for manual review, plus 20 unflagged
--    rows that contain broad banco/repo/embarg wording (possible misses)
WITH classified AS (
    SELECT id, title, txt,
-- BEGIN distress_text_flag CASE
    CASE
        WHEN txt ~* '\mrepose(i|í|ie)d[ao]s?\M'           THEN 'reposeida'
        WHEN txt ~* '\mrepossess\w*'                     THEN 'repossessed'
        WHEN txt ~* '\mbank[- ]owned\M'                  THEN 'bank_owned'
        WHEN txt ~* '\mpropiedad(es)? del banco\M'       THEN 'propiedad_del_banco'
        WHEN txt ~* '\membargad[ao]s?\M'                 THEN 'embargada'
        WHEN txt ~* '\mejecuci[oó]n de hipoteca\M'       THEN 'ejecucion_de_hipoteca'
        WHEN txt ~  '\mREO\M'                            THEN 'reo'
        WHEN txt ~* '\mforeclos\w*'                      THEN 'foreclosure'
        WHEN txt ~* '\mpropiedad(es)? (de )?hud\M|\mhud[- ]owned\M|\mhud homes?\M|\msubasta de hud\M|\mhud (escoge|se reserva)\M|\m(hud #?|caso )501-\d{6}\M' THEN 'hud_owned'
        WHEN txt ~* '\mhome ?path\M'                   THEN 'homepath'
    END AS distress_text_flag
-- END distress_text_flag CASE
    FROM (SELECT id, title,
-- BEGIN distress_text_flag CLEAN
          regexp_replace(coalesce(title, '') || ' ' || coalesce(description, ''),
                         '(nuestros? inventarios?[^.;:!]*|listado[^.;:!]{0,40}repose(i|í|ie)d\w*|pida nuestro[^.;:!]*|re[ -]?venta (y|o) repose(i|í|ie)d\w*)',
                         ' ', 'gi') AS txt
-- END distress_text_flag CLEAN
          FROM listings) x
), ranked AS (
    SELECT coalesce(distress_text_flag,
                    CASE WHEN txt ~* '(banco|repo|embarg)' THEN 'unflagged_broad_match' END) AS class,
           id, title, txt
    FROM classified
)
SELECT class, id, left(title, 40) AS title,
       substring(txt FROM '(?i).{0,60}(?:repose|repossess|bank[- ]owned|del banco|embargad|ejecuci[oó]n de hipoteca|REO|foreclos|hud|home ?path|banco|repo|embarg).{0,40}') AS context
FROM (SELECT *, row_number() OVER (PARTITION BY class ORDER BY random()) AS rn
      FROM ranked WHERE class IS NOT NULL) r
WHERE rn <= 20
ORDER BY class, rn;
