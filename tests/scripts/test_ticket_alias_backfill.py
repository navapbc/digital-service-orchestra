"""Tests for ticket_reducer._alias.compute_alias and the read-time backfill
applied by ticket_reducer._processors.process_create.

Behaviours under test:
  - compute_alias returns adj-noun-noun for full 16-hex IDs
  - compute_alias returns adj-noun (2 words) for legacy 8-hex IDs
  - compute_alias returns the same value as the shipped ticket-alias-compute.py
    shell helper (cross-implementation parity)
  - process_create populates state['alias'] from data.alias when present
  - process_create backfills state['alias'] from ticket_id when data.alias missing
"""

import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "plugins" / "dso" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from ticket_reducer._alias import compute_alias  # noqa: E402
from ticket_reducer import reduce_ticket  # noqa: E402


def test_compute_alias_full_id_three_words():
    alias = compute_alias("0193-d61d-abcd-1234")
    assert alias is not None
    parts = alias.split("-")
    assert len(parts) == 3, f"expected adj-noun-noun, got {alias!r}"


def test_compute_alias_legacy_8hex_two_words():
    alias = compute_alias("0193-d61d")
    assert alias is not None
    parts = alias.split("-")
    assert len(parts) == 2, f"expected adj-noun, got {alias!r}"


def test_compute_alias_too_short_returns_none():
    assert compute_alias("abc") is None
    assert compute_alias("") is None


def test_compute_alias_matches_shell_helper():
    """Module fallback must match the existing shell-side computation byte-for-byte
    so backfilled aliases for legacy tickets are the same as if they had been
    written at create time."""
    shell = SCRIPTS / "ticket-alias-compute.py"
    wordlist = REPO_ROOT / "plugins" / "dso" / "resources" / "ticket-wordlist.txt"
    assert shell.exists()
    assert wordlist.exists()
    for tid in ("0193-d61d-abcd-1234", "ffff-0000-1111-2222"):
        out = subprocess.run(
            [sys.executable, str(shell), tid, str(wordlist)],
            capture_output=True,
            text=True,
            check=True,
        )
        assert out.stdout.strip() == compute_alias(tid)


def _plant_ticket(root: Path, ticket_id: str, alias_in_data: str | None) -> Path:
    """Write a minimal CREATE event for ticket_id, optionally with data.alias."""
    td = root / ticket_id
    td.mkdir(parents=True, exist_ok=True)
    ts = time.time_ns()
    ev = str(uuid.uuid4())
    data = {"ticket_type": "task", "title": "test"}
    if alias_in_data is not None:
        data["alias"] = alias_in_data
    payload = {
        "timestamp": ts,
        "uuid": ev,
        "event_type": "CREATE",
        "env_id": "",
        "author": "test",
        "data": data,
    }
    (td / f"{ts}-{ev}-CREATE.json").write_text(json.dumps(payload))
    return td


def test_process_create_uses_stored_alias_when_present(tmp_path):
    td = _plant_ticket(tmp_path, "aaaa-bbbb-cccc-dddd", "stored-alias-here")
    state = reduce_ticket(str(td))
    assert state["alias"] == "stored-alias-here"


def test_process_create_backfills_when_alias_missing(tmp_path):
    """Legacy tickets (no data.alias on CREATE) should surface a computed alias."""
    td = _plant_ticket(tmp_path, "0193-d61d-abcd-1234", alias_in_data=None)
    state = reduce_ticket(str(td))
    expected = compute_alias("0193-d61d-abcd-1234")
    assert state["alias"] == expected
    assert state["alias"] is not None
