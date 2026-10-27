"""
Drift guard for analysis/claims/*.sql: every file repeats the same BASE
block (filters, variants, payment factor), since the read-only queries
can't share a view. All copies must be identical, and no claim may read
listings.status (unreliable; see SPRINT.md).
"""

import re
from pathlib import Path

CLAIMS = sorted((Path(__file__).resolve().parent.parent / "analysis" / "claims").glob("*.sql"))
BASE = re.compile(r"-- BEGIN claims BASE\n(.*?)-- END claims BASE", re.S)


def test_every_claim_has_identical_base():
    found = [b for f in CLAIMS for b in BASE.findall(f.read_text())]
    assert len(CLAIMS) >= 4
    assert len(found) >= len(CLAIMS)
    assert len(set(found)) == 1


def test_no_claim_uses_status():
    for f in CLAIMS:
        sql = "\n".join(l for l in f.read_text().splitlines() if not l.lstrip().startswith("--"))
        assert not re.search(r"\bstatus\b", sql, re.I), f.name
