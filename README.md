# Puerto Rico housing affordability: a checked analysis

A Puerto Rico real estate data pipeline and affordability analysis: a
personal, non-commercial exercise.

The repository publishes the queries behind each figure, aggregate
exports, and the record of what was checked. It does not publish
listing-level data or the code that collected it (see "Provenance").

## Headline

**A mortgage on the median listing costs 87.5% of the local median
household's monthly income.**

| | Value | Source |
|---|---|---|
| Listings (for sale, houses and apartments, duplicate copies excluded) | 5,621 | `analysis/exports/muni_type_summary.csv` (island, all) |
| Median asking price | $310,000 | same row |
| Income used: listing-weighted average of municipio median household incomes | $26,870 per year | same row |
| Mortgage payment as % of that monthly income | **87.5%** | same row; `analysis/claims/headline_pct_income.sql` |
| Snapshot | Mar-Jun 2026 | same row, `snapshot_window` |

By type: houses 84.6% (n 3,984), apartments 91.7% (n 1,637)
(`analysis/exports/muni_type_summary.csv`, island rows).

**What the payment includes:** principal and interest only. It assumes
5% down, a 7% fixed rate and 30 years (`analysis/claims/RESULTS.md`).

**What it excludes:** property tax, home and flood insurance, mortgage
insurance, condominium or association fees, maintenance and closing
costs. So the true cost of ownership is higher than this figure.

**Other definitions:**
- **Prices** are asking prices, not sale prices.
- **Listings included:** for sale, houses and apartments, priced
  $20,000–$2,400,000.
- **Income** is the ACS 2019–2023 5-year median household income of each
  listing's municipio (`analysis/exports/census_income.csv`), averaged
  over the listings. It is not a Puerto Rico-wide median, which is not in
  this dataset.

**A second figure:** a household earning $80,000 a year can afford up to
$295,341 at 28% of income on the same loan terms. 47.6% of the listings
are at or below that price (`analysis/claims/RESULTS.md`;
`analysis/claims/price_histogram.sql`).

The Tableau Public dashboard for this project currently shows an earlier
extract (April 7, 2026, with duplicate listings not removed), so its
headline differs from the figure above. It is being rebuilt on the
deduplicated snapshot described here.

## Method

**Deduplication.** The same property is often posted more than once.
- **Rule:** listings are grouped when they share barrio, municipio, price,
  bedrooms, bathrooms and property type, and do not disagree on map
  location. One listing per group is kept
  (`pipeline/deduplication.py`).
- **Result:** 348 groups, covering 875 listings; 527 repeat copies are
  excluded (`analysis/exports/conflict_ledger.csv`). 498 of those fall
  inside the headline's filters, which takes 6,119 listings to 5,621
  (`analysis/claims/RESULTS.md`; `analysis/quality/dedup_checks.sql`).
- **Limit:** the rule needs beds, baths and type. 45.6% of all listings
  lack one of them, and so do 570 of the 6,609 houses and apartments.
  Duplicates among those can't be checked
  (`analysis/exports/conflict_ledger.csv`).

**Near-duplicate review.** Looser matches are listed for review but not
removed (`analysis/exports/near_duplicate_tiers.csv`):
- tier A, same area, size and price within 2%: 258 pairs, 418 listings;
- tier B: 3 pairs, 6 listings;
- tier C: no pairs;
- tier D: 30 pairs, 59 listings.

Collapsing tier A leaves the headline at 87.5% (n 5,621 → 5,399;
`analysis/claims/RESULTS.md`, robustness checks).

**Barrio names.** 54 groups of barrio spellings differ only by spacing or
case and are mapped to one name, though that mapping isn't yet applied
to any figure. 352 listing and rental barrio names are exactly 30
characters long, which looks like a field limit. 25 pairs that differ by words like "de" or "la" are flagged
for review, not merged (`analysis/exports/conflict_ledger.csv`).

**What the source lacks** (`analysis/exports/conflict_ledger.csv`):
- **No address field:** the listings data has no address field.
- **No tax-parcel link:** no listing is linked to a tax parcel.
- **No exact locations:** map locations are one shared pin per barrio,
  not the property (12,027 listings).

So no figure here is at address, parcel or sub-barrio level.

**Small samples.** Of the 132 municipio × type cells, 36 have fewer than
10 listings and should not be shown; 83 have fewer than 30 and need a
caveat (`analysis/claims/RESULTS.md`). Each row of
`analysis/exports/muni_type_summary.csv` carries both flags.

## What I found wrong in my own work

- **A status field that measured nothing.** The collector marked a
  listing as repossessed when the page contained the word "Repo". It
  matched the site's "Reportar" (report) link on most pages. The
  field was reset. No repossession share is published; 0 of 12,548
  listings have a reliable status (`analysis/exports/conflict_ledger.csv`).
  What remains is listings that say so in their own text: 44
  (`analysis/exports/distress_ledger.csv`).
- **A migration that would have done nothing.** A fix meant to remove 297
  listings that had already sold from the for-sale count filtered on a
  value an earlier step had cleared. As written, it would have changed
  none of them. It was corrected before running; the 297 are excluded
  (`analysis/exports/conflict_ledger.csv`).
- **A changed bounding box.** An edit overwrote the coordinates of a
  sampling area. 1,084 tax-grid samples were drawn from the wrong box and
  over-represent two municipios. They are flagged, and no tax figure is
  published here (`analysis/exports/conflict_ledger.csv`).
- **Figures I could not reproduce.** An earlier version of this
  repository stated affordability and tax figures that no checked-in
  query reproduces. They were removed and are not repeated here. Every
  figure now comes from a query listed in `analysis/claims/RESULTS.md`.

## Limitations

- **One snapshot:** listings were collected Mar-Jun 2026. 97.6% of the
  for-sale listings were not re-checked after that
  (`analysis/exports/conflict_ledger.csv`), so some may have sold or been
  withdrawn.
- **Asking prices, not sale prices.**
- **Income is a municipio median, not the buyer's income.** Municipio
  medians come from 2019–2023 survey data.
- **The payment excludes taxes, insurance and fees** (see "Headline").
- **Deduplication is partial:** it can't check listings that lack beds,
  baths or type.
- **Locations are barrio-level.**
- **One source:** listings come from a single classifieds site, which
  does not cover the whole market.

## Provenance

- Listings were collected from a public classifieds website whose terms
  restrict automated access. This was done for a personal exercise.
- Only aggregates are published: no listing IDs, URLs, titles,
  descriptions, seller details, addresses or listing coordinates.
- The collection code is not published.
- Anything beyond a personal exercise would use a licensed or otherwise
  permitted data feed.
- Income data: US Census Bureau, American Community Survey 2019–2023
  5-year estimates, tables B19013 and B19080
  (`analysis/exports/README.md`).

## How to verify

- **`analysis/claims/RESULTS.md`** lists each figure with the query that
  produces it and that file's git blob hash.
- **`analysis/exports/`** holds the aggregate outputs and a data
  dictionary (`analysis/exports/README.md`).
- **`analysis/exports/reconciliation.csv`** lists every on-screen value
  and the export it comes from.
- **Checking the headline:** recompute it from the exports with
  `median_price × 0.95 × payment factor ÷ (median_income ÷ 12)`, where the
  payment factor is `r(1+r)^360 / ((1+r)^360 − 1)` and `r = 0.07/12`.
  For example, $310,000 and $26,870 give 87.5%.
- **The SQL in `analysis/claims/` and `analysis/quality/`** documents
  exactly how each figure was computed.
- **Drift guards:** `tests/` checks that the SQL blocks shared between
  queries are identical and that no figure uses the status field:
  `uv run --with pytest pytest tests/`.

The full dataset is not published, so the queries and the pipeline
cannot be re-run from this repository. They run against a private
PostgreSQL database whose schema is also not published.

## Contents

```
analysis/claims/    queries for each published figure, and RESULTS.md
analysis/quality/   data-quality checks (dedup, near-duplicates, barrio names, ledger)
analysis/exports/   aggregate CSVs and their data dictionary
pipeline/           deduplication rule
tests/              drift guards for the shared SQL blocks
```
