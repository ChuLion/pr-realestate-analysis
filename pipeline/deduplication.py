"""
Listing Deduplication

Requires a PostgreSQL database with a `listings` table and a
`listing_duplicate_groups` table (unique on the match key below). That
schema and the data are not published, so this module documents the
rule; it cannot be run from this repository. Checks of its result:
analysis/quality/dedup_checks.sql.

METHODOLOGY:

Match key: exact (barrio, municipality_normalized, price, bedrooms,
bathrooms, property_type) — all non-null. Within a matching group, every
member must additionally agree on (lat, lon) wherever populated.

This two-part key was arrived at empirically, not assumed. Exact lat/lon
match alone is NOT usable as a standalone key: listing coordinates are
barrio-level or search-default pins, shared by unrelated listings. But
combined with the spec-tuple match, lat/lon agreement is a useful
CONFIRMING signal: in the duplicate clusters reviewed during
investigation, copies of one property posted by several brokers almost
always shared an exact coordinate.

This is deliberately CONSERVATIVE — precision over recall, because this
feeds published median/count statistics:
  - If any two members of a spec-tuple group have DIFFERENT non-null
    coordinates, the WHOLE group is left unflagged rather than guessed
    at. This is the guard against the main false-positive risk: two
    different units in the same new development sharing an identical
    floor plan and price tier are not duplicates of each other.
  - Re-posts by the same broker and by several brokers of one real
    property are both covered by the same rule. The listing status field is not
    used (it is unreliable; see analysis/exports/conflict_ledger.csv).

KNOWN LIMITATION — stated explicitly here and in README.md: 45.6% of
listings (analysis/exports/conflict_ledger.csv) are missing
bedrooms, bathrooms, or property_type and are therefore NOT covered by
this pass at all. They are neither flagged as duplicates nor confirmed
unique — is_primary_in_group stays NULL for them, exactly as it does for
genuinely unique listings. Callers must not treat NULL as "verified
unique." A description/title-similarity pass could extend coverage here,
but PR listing titles are frequently generic ("Urbanizacion - X, Y") and
a naive text match risks false positives without materially more work —
out of scope for this version.

Never deletes or merges rows. Only sets duplicate_group_id and
is_primary_in_group on `listings`. Aggregate queries (barrio medians,
listing counts) must filter:

    WHERE is_primary_in_group IS NOT FALSE

USAGE:
    python pipeline/deduplication.py --dry-run   # preview only, no writes
    python pipeline/deduplication.py             # detect + write
    python pipeline/deduplication.py --stats     # summary of current state
"""

import argparse
import os

import psycopg2
from dotenv import load_dotenv

load_dotenv()
DB_CONFIG = os.getenv("DB_CONFIG", "dbname=pr_realestate host=localhost")


# ── Matching ──────────────────────────────────────────────────────────────────

FIND_CANDIDATE_GROUPS_SQL = """
    SELECT
        barrio, municipality_normalized, price, bedrooms, bathrooms, property_type,
        -- NULL if members disagree; the agreed-upon value otherwise (min()
        -- is arbitrary among equal values — this is not an aggregation,
        -- just a way to surface "the" value when count(DISTINCT) = 1)
        CASE WHEN count(DISTINCT lat) <= 1 THEN min(lat) ELSE NULL END AS lat,
        CASE WHEN count(DISTINCT lon) <= 1 THEN min(lon) ELSE NULL END AS lon,
        count(*) AS member_count,
        -- Best-first ordering: the row an aggregate query should keep as
        -- primary is the most complete one (real detail scrape, contact
        -- fields filled), tie-broken by earliest sighting, then id for a
        -- fully deterministic order.
        array_agg(id ORDER BY
            (detail_status = 'ok') DESC,
            (seller_name IS NOT NULL AND seller_name != 'Unknown') DESC,
            (agency_name IS NOT NULL AND agency_name != 'Unknown') DESC,
            scraped_at ASC,
            id ASC
        ) AS ids_best_first
    FROM listings
    WHERE bedrooms IS NOT NULL
      AND bathrooms IS NOT NULL
      AND property_type IS NOT NULL
    GROUP BY barrio, municipality_normalized, price, bedrooms, bathrooms, property_type
    HAVING count(*) > 1
       AND count(DISTINCT lat) <= 1
       AND count(DISTINCT lon) <= 1
"""


def find_candidate_groups(cur):
    cur.execute(FIND_CANDIDATE_GROUPS_SQL)
    columns = ['barrio', 'municipality_normalized', 'price', 'bedrooms',
               'bathrooms', 'property_type', 'lat', 'lon', 'member_count',
               'ids_best_first']
    return [dict(zip(columns, row)) for row in cur.fetchall()]


# ── Database ──────────────────────────────────────────────────────────────────

def reset_all(cur, conn):
    """
    Clear all previous dedup flags before recomputing from scratch. Safe
    and cheap at this row count — avoids stale flags lingering after a
    listing's price/specs change and it no longer belongs to its old
    group. Rows in listing_duplicate_groups are never deleted (harmless
    historical residue if a group empties out), only listings' pointers
    to them.
    """
    cur.execute("""
        UPDATE listings
        SET duplicate_group_id = NULL, is_primary_in_group = NULL
        WHERE duplicate_group_id IS NOT NULL OR is_primary_in_group IS NOT NULL
    """)
    conn.commit()
    return cur.rowcount


def upsert_group(cur, conn, group):
    """Idempotent: the same match key always maps to the same group_id."""
    cur.execute("""
        INSERT INTO listing_duplicate_groups
            (barrio, municipality_normalized, price, bedrooms, bathrooms,
             property_type, lat, lon, member_count, detected_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, NOW())
        ON CONFLICT (barrio, municipality_normalized, price, bedrooms,
                     bathrooms, property_type, lat, lon)
        DO UPDATE SET member_count = EXCLUDED.member_count,
                      detected_at  = NOW()
        RETURNING group_id
    """, (
        group['barrio'], group['municipality_normalized'], group['price'],
        group['bedrooms'], group['bathrooms'], group['property_type'],
        group['lat'], group['lon'], group['member_count'],
    ))
    group_id = cur.fetchone()[0]
    conn.commit()
    return group_id


def apply_group(cur, conn, group_id, ids_best_first):
    primary_id = ids_best_first[0]
    other_ids = ids_best_first[1:]

    cur.execute("""
        UPDATE listings SET duplicate_group_id = %s, is_primary_in_group = TRUE
        WHERE id = %s
    """, (group_id, primary_id))

    if other_ids:
        cur.execute("""
            UPDATE listings SET duplicate_group_id = %s, is_primary_in_group = FALSE
            WHERE id = ANY(%s)
        """, (group_id, other_ids))

    conn.commit()


def print_stats(cur):
    cur.execute("""
        SELECT
            count(*) FILTER (WHERE is_primary_in_group = TRUE)  AS primaries,
            count(*) FILTER (WHERE is_primary_in_group = FALSE) AS excluded,
            count(*) FILTER (WHERE is_primary_in_group IS NULL) AS not_flagged,
            count(*) AS total
        FROM listings
    """)
    primaries, excluded, not_flagged, total = cur.fetchone()
    print(f"\n📊 Current state: {total:,} total listings")
    print(f"   Primary (counted in aggregates):  {primaries:,}")
    print(f"   Flagged duplicate (excluded):     {excluded:,}")
    print(f"   Not flagged (unique, or missing specs — see module docstring "
          f"for the ~46% coverage limitation): {not_flagged:,}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Detect and flag duplicate listings — same property, "
                    "multiple agencies/postings. See module docstring for "
                    "methodology and its known coverage limitation."
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview candidate groups without writing")
    parser.add_argument("--stats", action="store_true",
                        help="Print current dedup state and exit")
    args = parser.parse_args()

    conn = psycopg2.connect(DB_CONFIG)
    cur = conn.cursor()
    print("✅ Database connected")

    if args.stats:
        print_stats(cur)
        cur.close()
        conn.close()
        return

    groups = find_candidate_groups(cur)
    total_rows = sum(g['member_count'] for g in groups)
    total_excess = sum(g['member_count'] - 1 for g in groups)
    print(f"🔍 Found {len(groups)} candidate duplicate groups "
          f"({total_rows} rows involved, {total_excess} would be excluded "
          f"from aggregates)")

    if args.dry_run:
        print("\n--dry-run — no changes written. Sample groups:")
        for g in groups[:10]:
            price_str = f"${g['price']:,.0f}" if g['price'] is not None else "N/A"
            print(f"  {g['barrio']}, {g['municipality_normalized']} | {price_str} | "
                  f"{g['bedrooms']}bd/{g['bathrooms']}ba {g['property_type']} | "
                  f"{g['member_count']} listings: {g['ids_best_first']}")
        cur.close()
        conn.close()
        return

    reset_count = reset_all(cur, conn)
    print(f"🔄 Reset {reset_count} previously-flagged rows before recomputing")

    for g in groups:
        group_id = upsert_group(cur, conn, g)
        apply_group(cur, conn, group_id, g['ids_best_first'])

    print(f"✅ Applied {len(groups)} groups — {total_excess} rows flagged "
          f"is_primary_in_group=FALSE")
    print_stats(cur)

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
