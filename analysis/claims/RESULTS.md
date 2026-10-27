# Claims results

Every published figure appears here with the query that produces it and
the file's git blob SHA (short). Data: a snapshot of listings collected
Mar–Jun 2026 (last collection 2026-06-09), after deduplication.

- **Filters (all figures):** listings for sale, property type house
  (`casa`) or apartment (`apartamento`), price $20,000–$2,400,000. The
  listing status field is not used anywhere (enforced by
  `tests/test_claims_sql.py`).
- **Mortgage rule:** 5% down, 7% fixed, 30 years; principal and interest
  only. The affordable price uses a 28% front-end ratio.
- **Variants:** the full snapshot without deduplication, and the full
  snapshot deduplicated. **The deduplicated figure is published.** The
  queries also report an earlier cut of the data, which is not used.

| Query file | SHA |
|---|---|
| `headline_pct_income.sql` | `4a16b5b33dbe` |
| `affordable_home_price.sql` | `afc4a0965a15` |
| `muni_type_summary.sql` | `27a375122a88` |
| `price_histogram.sql` | `185443407b0e` |
| `price_bins.sql` | `dcc9cb428b53` |
| `price_bins_checks.sql` | `8c03c781b7e3` |

## Figures

| Figure | Full, no dedup | Full, dedup (published) |
|---|---|---|
| Mortgage on the median listing, % of median monthly income | 85.8% (n 6,119) | **87.5%** (n 5,621) |
| Listings | 6,119 | **5,621** |
| Median asking price | $305,000 | **$310,000** |
| Income used (listing-weighted average of municipio medians) | $26,958 | **$26,870** |
| Affordable price at the median income (p50) | $99,522 | **$99,197** |
| Affordable price at p80 income | $227,610 | **$227,317** |
| Affordable price at p95 income | $471,208 | **$471,285** |
| Affordable price at $80,000 income | $295,341 | **$295,341** |
| Share of listings at or below $295,341 | 48.0% (2,938 / 6,119) | **47.6%** (2,676 / 5,621) |

- **Affordable price** = income ÷ 12 × 0.28 ÷ payment factor ÷ 0.95. The
  p80 and p95 incomes are ACS income-distribution limits (B19080),
  averaged over the listings in the same way.
- **The price histogram** (`price_histogram.sql`) uses $50,000 bins, with
  an open last bin from $1,000,000.

### Income

The income is `AVG(median_income)` over the deduplicated listing rows:
each municipio's ACS 2019–2023 median household income (B19013) weighted
by its number of listings. It is not the Puerto Rico-wide median
household income, which is not in the database. Label: "% of the local
median household's monthly income (listing-weighted average of municipio
medians)".

### Municipality × type

`muni_type_summary.sql` returns three levels:

- **island:** all / casa / apartamento. Deduplicated: all 87.5% (n 5,621),
  casa 84.6% (n 3,984), apartamento 91.7% (n 1,637).
- **municipality:** the 78 census municipios, with the sub-areas of San
  Juan, Carolina, Humacao and Toa Baja rolled up. Deduplicated: 132 cells,
  36 with n < 10, 83 with n < 30.
- **sub_area:** Condado-Miramar, Hato Rey, Río Piedras, Santurce, Viejo
  SJ, Isla Verde, Palmas, Levittown, each using its parent municipio's
  income. Deduplicated: 16 cells, 1 with n < 10, 6 with n < 30.

Cells with n < 10 are not to be shown; cells with n < 30 need a
small-sample caveat. The deduplicated variant is exported to
`analysis/exports/muni_type_summary.csv`, with a `snapshot_window`
column ("Mar-Jun 2026") derived from the data.

### Price bins ($5,000)

`price_bins.sql` (deduplicated) feeds `analysis/exports/price_bins.csv`.
`price_bins_checks.sql` proves that bin sums equal every cell's n. It
also measures how far a share read from the bins ("share of listings at
or below the affordable price") is from the exact share:

| Income | Affordable price | Exact | From bins (interpolated) | Gap |
|---|---|---|---|---|
| $40,000 | $147,671 | 12.7% | 12.6% | −0.1 |
| $60,000 | $221,506 | 30.5% | 30.2% | −0.3 |
| $80,000 | $295,341 | 47.6% | 46.9% | −0.7 |
| $120,000 | $443,012 | 67.1% | 67.1% | −0.1 |

All gaps are under 1 point. At $80,000 the bins bound the share between
46.8% (bins entirely below) and 48.4% (including the straddling bin),
because many listings sit at exactly $295,000. The exact 47.6% is the
published figure.

Examples, deduplicated:

| Area | Type | n | Median price | % of income |
|---|---|---|---|---|
| Dorado | casa | 110 | $672,000 | 152.7% |
| San Juan – Condado-Miramar | apartamento | 188 | $690,000 | 194.0% |
| Bayamón | apartamento | 25 (n<30) | $210,000 | 51.8% |
| Bayamón | casa | 224 | $249,950 | 61.7% |

## Robustness checks (not published figures)

| Check | Result | Query file | SHA |
|---|---|---|---|
| Near-duplicate tier A collapsed (one listing per pair; the later-collected one dropped) | n 5,621 → 5,399; median $310,000 → $310,000; headline 87.5% → 87.5% | `analysis/quality/near_duplicates.sql` (query 4) | `579d12c34047` |

The headline does not depend on the unmerged near-duplicate candidates.

Deduplication: 527 listings are flagged as repeat copies, 498 of them
inside the filters, which takes 6,119 listings to 5,621
(`analysis/quality/dedup_checks.sql`).

## Removed claims

An earlier version of this repository stated affordability, tax-gap and
listing-status figures that no checked-in query reproduces. They were
removed and are not restated. The listing status field is not used for
any figure, because the collector's rule matched a "Reportar" link
rather than a status (`analysis/exports/conflict_ledger.csv`).

## Not verified

- No tax-assessment figure is published, and there is no claims query
  for tax-gap or price-to-rent figures.
