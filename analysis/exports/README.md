# Exports — data dictionary

Aggregate-only extracts, built read-only from a private PostgreSQL
database by a build script that is not published.

Data: snapshot of listings collected Mar–Jun 2026 (last collection
2026-06-09). Published figures and how they were checked are in
`analysis/claims/RESULTS.md`.

**What is not included:** no listing IDs, titles, URLs, descriptions,
seller names, phone numbers, addresses or listing coordinates. Listings have
no address column, so there is none to export. No export contains
coordinates. Every export was checked against all 30,802 listing, rental
and sold IDs (see "Checks").

Common terms:

- **Base:** `v_market_unified` sale rows, `property_type` casa (house) or
  apartamento (apartment), price $20,000–$2,400,000, dedup primaries only
  (the deduplicated figures in RESULTS.md).
- **Income:** ACS 2019–2023 municipal median household income (`census_income`).
- **pct_of_income:** monthly mortgage on the median price (5% down, 7%,
  30 years) ÷ monthly median income × 100.

| File | SHA (git blob) | Rows (excl. header) | Source |
|---|---|---|---|
| `muni_type_summary.csv` | `f63b26e244e3` | 151 | `analysis/claims/muni_type_summary.sql`, deduplicated |
| `price_bins.csv` | `8ff3ae6dfe85` | 4,209 | `analysis/claims/price_bins.sql` |
| `price_bins_island_1k.csv` | `7fb81b715dc8` | 1,664 | `analysis/claims/price_bins_island_1k.sql` |
| `census_income.csv` | `a32a54274c2f` | 78 | `census_income` table (build script) |
| `conflict_ledger.csv` | `fe2cc18ccc64` | 37 | `analysis/quality/conflict_ledger.sql` |
| `reconciliation.csv` | `bc864e80873a` | 63 | `analysis/claims/reconciliation.sql` (built last; reads the other exports) |
| `distress_ledger.csv` | `47f984ab4c28` | 21 | `listings.distress_text_flag` (build script) |
| `near_duplicate_tiers.csv` | `75e978756dce` | 4 | `analysis/quality/near_duplicates.sql`, query 1 |

`analysis/quality/export_checks.sql` re-reads the exports: `pct_of_income`
recomputed from each row's `median_price` and `median_income` equals the
exported value in all 151 rows (maximum difference 0.0), and
`census_income.csv` equals the table for all 78 municipios.

## muni_type_summary.csv

One row per level × area × property type.

| Column | Meaning |
|---|---|
| `level` | `island`, `municipality` (78 census municipios; sub-areas rolled up) or `sub_area` |
| `municipality` | Municipio name; empty for `island` |
| `sub_area` | Sub-area for `sub_area` rows (San Juan: Condado-Miramar, Hato Rey, Río Piedras, Santurce, Viejo SJ; Carolina: Isla Verde; Humacao: Palmas; Toa Baja: Levittown); empty otherwise |
| `property_type` | `all` (island only), `casa`, `apartamento` |
| `n` | Listings in the cell |
| `median_price` | Median asking price, $ |
| `median_income` | Municipal median household income, $. Island rows: listing-weighted average of municipal medians (the headline's income). Sub-areas: parent municipality's income |
| `pct_of_income` | See common terms. Island/all = 87.5% (the published headline) |
| `price_p25`, `price_p75` | 25th / 75th percentile asking price, $ |
| `flag_n_lt_10` | `t` = do not publish this cell |
| `flag_n_lt_30` | `t` = publish only with a small-sample caveat |
| `snapshot_window` | Month range of `scraped_at` over the base rows, derived by the query (not typed): `Mar-Jun 2026` (2026-03-24 to 2026-06-09). Same on every row; use it in the subtitle |

## price_bins.csv

Listing counts per $5,000 price bin, from the base.

| Column | Meaning |
|---|---|
| `scope` | `island` or `municipality` |
| `municipality` | Municipio (rolled up); empty for `island` |
| `property_type` | `all` (island only), `casa`, `apartamento` |
| `bin_floor` | Lower edge, $; bin covers [floor, floor + 5,000). The last bin ($2,395,000) also holds $2,400,000 |
| `n` | Listings in the bin |

Municipality bins exist only for cells with n ≥ 10 (96 cells); smaller
cells are counted in island scope only. Zero-count bins are omitted. Bin
sums equal each cell's n (`analysis/claims/price_bins_checks.sql`). Shares
read from bins differ from exact shares by under 1 point (largest −0.7 at
$80,000 income, interpolated); publish exact shares from RESULTS.md.

## price_bins_island_1k.csv

Island-only listing counts per $1,000 price bin, from the base.

| Column | Meaning |
|---|---|
| `property_type` | `all`, `casa`, `apartamento` |
| `bin_floor` | Lower edge, $; bin covers [floor, floor + 1,000). The last bin ($2,399,000) also holds $2,400,000 |
| `n` | Listings in the bin |

Zero-count bins are omitted. Bin sums equal n for each type (5,621 /
3,984 / 1,637). At $80,000 income ($295,341) the bins give 46.8% (bins
entirely below) to 47.6% (including the straddling bin) vs exact 47.6%;
interpolated 47.0%. At $40k, $60k and $120k the interpolated gap is 0.0
points (`analysis/claims/price_bins_checks.sql`, query 3).

## census_income.csv

ACS 2019–2023 5-year estimates per municipio, from the US Census Bureau
API (`for=county:*&in=state:72`).

| Column | Meaning |
|---|---|
| `municipality` | Census municipio (78) |
| `median_income` | Median household income, $ (B19013_001E) |
| `income_p20` | 20th percentile upper limit, $ (B19080_001E) |
| `income_p50` | Same as `median_income` (B19013_001E) |
| `income_p80` | 80th percentile upper limit, $ (B19080_004E) |
| `income_p95` | Top 5% lower limit, $ (B19080_005E) |
| `acs_vintage` | `ACS 2019-2023 5-year` |

Example: Moca p80 = 51,528, p95 = 119,289.

Affordable price at p80 income = income_p80 ÷ 12 × 0.28 ÷ payment factor
÷ 0.95. For Moca at 5% down, 7% and 30 years: $190,229.26.

## conflict_ledger.csv

The Data Health ledger, one row per known data issue. No listing IDs.

| Column | Meaning |
|---|---|
| `issue` | Short name |
| `description` | Technical description, with live counts where relevant |
| `rows_affected`, `base_rows`, `pct` | Count, denominator, share (%) |
| `blocks_publishing` | `no`, `caveat (…)` or `yes (scope)` |
| `source_check` | Query or migration that proves it |
| `display_text` | Plain-English line for the dashboard (≤ 120 characters; longest 99) |

One row is relative to the build date: `sold_date future (tier 2)` counts
sold dates after `CURRENT_DATE` (17 on 2026-10-23, 16 on 2026-10-27,
after one dated 2026-10-24 passed). The data did not change.

## reconciliation.csv

Every value that must appear on screen, read back from the export that
holds it. Use it to check the dashboard number by number.

| Column | Meaning |
|---|---|
| `section` | island, municipality, dedup, near-duplicate candidates, distress wording |
| `item` | What the value is |
| `value` | The value as exported |
| `unit` | listings, USD, USD/year, %, flag, groups, pairs, properties |
| `source_file` | Export file it was read from. The two $80,000 rows (affordable price $295,341, share 47.6%) are not in any export and cite `analysis/claims/price_histogram.sql` and RESULTS.md |

Municipality cells included: Moca casa, Aguada apartamento, San Juan
apartamento, Dorado casa, Ponce casa.

## distress_ledger.csv

Listings whose own text states distress or bank, HUD or lender ownership
(`listings.distress_text_flag`). Text evidence only, not proof of
ownership.

| Column | Meaning |
|---|---|
| `scope` | `island` (one row per pattern) or `municipality` |
| `distress_text_flag` | Pattern class: `hud_owned`, `homepath`, `reposeida`, `embargada` (others defined but unmatched) |
| `municipality` | Municipio; empty for `island` |
| `listings` | Listing rows with the pattern |
| `distinct_properties` | Same, counting each dedup group once (e.g. 28 hud_owned listings = 14 properties) |

## near_duplicate_tiers.csv

Candidate near-duplicate pairs among base listings, for review only. Not
applied to any figure (RESULTS.md, robustness checks).

| Column | Meaning |
|---|---|
| `tier` | A: same municipality, canonical barrio, type, beds, baths, price within 2%, ≤ 25 m. B: as A, coordinates missing on one side. C: as A, 25–100 m. D: same exact price, baths differ by ≤ 0.5 or sqft differs |
| `pairs` | Candidate pairs in the tier |
| `listings_involved` | Distinct listings in those pairs |
| `base_primaries` | Listings in the base (5,621) |
| `pct_of_base` | listings_involved ÷ base_primaries × 100 |

Listing coordinates are barrio-level pins, so distance rarely separates
units: all tier A pairs are 0 m apart and tier C is empty.

## Checks

After every build, every number in every export is compared with the
30,802 listing, rental and sold IDs in the private database. As of
2026-10-27, apart from one price-bin floor (a price, in `price_bins.csv`
and `price_bins_island_1k.csv`), no number in any export matches an ID.
