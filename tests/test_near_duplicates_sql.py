"""
Drift guard: the near-duplicate PAIRS block (population, blocking, tiers)
is repeated in each query of near_duplicates.sql and in the Data Health
ledger, since the read-only queries can't share a view. All copies must be
identical.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    ROOT / "analysis" / "quality" / "near_duplicates.sql",
    ROOT / "analysis" / "quality" / "conflict_ledger.sql",
]
BLOCK = re.compile(r"-- BEGIN near_duplicates PAIRS\n(.*?)-- END near_duplicates PAIRS", re.S)


def test_pairs_blocks_identical():
    found = [b for f in FILES for b in BLOCK.findall(f.read_text())]
    assert len(found) == 5  # 4 queries + the ledger
    assert len(set(found)) == 1


def test_population_is_published_base_primaries():
    block = BLOCK.findall(FILES[0].read_text())[0]
    assert "is_primary_in_group IS DISTINCT FROM FALSE" in block
    assert "v.price BETWEEN 20000 AND 2400000" in block
    assert "barrio_canonical" in block
