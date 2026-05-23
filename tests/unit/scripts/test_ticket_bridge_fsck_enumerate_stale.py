"""Unit tests for enumerate_stale_anomalies() in ticket-bridge-fsck.py.

Tests cover:
  - test_enumerate_stale_returns_list: seeded stale ticket returns list of
    length 1.
  - test_enumerate_stale_record_shape: each record has ticket_id, jira_key,
    last_sync_ts, class_label, and proposed_remediation.
  - test_enumerate_stale_matches_audit_output: result entries match
    audit_bridge_mappings(dir)['stale'] plus the two enrichment fields.
  - test_enumerate_stale_cli_backward_compat: CLI report output is identical
    after adding the new function.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import time
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-bridge-fsck.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "ticket_bridge_fsck",
        SCRIPT_PATH,
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def fsck() -> ModuleType:
    """Return the ticket_bridge_fsck module; fail all tests if absent."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"ticket-bridge-fsck.py not found at {SCRIPT_PATH}",
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# 31 days in nanoseconds — guaranteed to be stale relative to any reasonable now
_31_DAYS_NS = 31 * 24 * 3600 * 1_000_000_000


def _write_event(ticket_dir: Path, filename: str, payload: dict) -> None:
    ticket_dir.mkdir(parents=True, exist_ok=True)
    (ticket_dir / filename).write_text(json.dumps(payload))


def _seed_stale_ticket(
    tracker: Path,
    ticket_id: str = "ticket-stale-0001",
    jira_key: str = "TEST-999",
    now_ns: int | None = None,
) -> int:
    """Create a ticket with CREATE + stale SYNC (>30 days old, no BRIDGE_ALERT).

    Returns the sync timestamp used so tests can assert against it.
    """
    if now_ns is None:
        now_ns = time.time_ns()
    stale_ts = now_ns - _31_DAYS_NS

    ticket_dir = tracker / ticket_id
    _write_event(
        ticket_dir,
        "0001-CREATE.json",
        {"event_type": "CREATE", "ticket_id": ticket_id},
    )
    _write_event(
        ticket_dir,
        "0002-SYNC.json",
        {
            "event_type": "SYNC",
            "ticket_id": ticket_id,
            "jira_key": jira_key,
            "timestamp": stale_ts,
        },
    )
    return stale_ts


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_enumerate_stale_returns_list(fsck: ModuleType) -> None:
    """Seeded stale ticket returns a list of exactly one record."""
    now_ns = time.time_ns()
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_stale_ticket(tracker, now_ns=now_ns)

        results = fsck.enumerate_stale_anomalies(tracker, now=now_ns)

    assert isinstance(results, list), "enumerate_stale_anomalies must return a list"
    assert len(results) == 1, f"Expected 1 stale record, got {len(results)}"


def test_enumerate_stale_record_shape(fsck: ModuleType) -> None:
    """Each record contains ticket_id, jira_key, last_sync_ts, class_label, and proposed_remediation."""
    now_ns = time.time_ns()
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        stale_ts = _seed_stale_ticket(
            tracker,
            ticket_id="ticket-shape-0001",
            jira_key="SHAPE-1",
            now_ns=now_ns,
        )

        results = fsck.enumerate_stale_anomalies(tracker, now=now_ns)

    assert len(results) == 1
    record = results[0]

    # Core identity fields
    assert record["ticket_id"] == "ticket-shape-0001"
    assert record["jira_key"] == "SHAPE-1"
    assert record["last_sync_ts"] == stale_ts

    # Enrichment fields
    assert "class_label" in record, "record missing 'class_label'"
    assert record["class_label"] == "stale", (
        f"class_label must be 'stale', got {record['class_label']!r}"
    )

    assert "proposed_remediation" in record, "record missing 'proposed_remediation'"
    assert record["proposed_remediation"] == "re-sync or close", (
        f"proposed_remediation must be 're-sync or close', "
        f"got {record['proposed_remediation']!r}"
    )


def test_enumerate_stale_matches_audit_output(fsck: ModuleType) -> None:
    """Returned entries correspond to audit_bridge_mappings['stale'] plus enrichment fields."""
    now_ns = time.time_ns()
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_stale_ticket(
            tracker,
            ticket_id="ticket-audit-0001",
            jira_key="AUDIT-1",
            now_ns=now_ns,
        )

        audit = fsck.audit_bridge_mappings(tracker, now_ts=now_ns)
        results = fsck.enumerate_stale_anomalies(tracker, now=now_ns)

    raw_stale = audit["stale"]
    assert len(results) == len(raw_stale), (
        "enumerate_stale_anomalies must return one record per raw stale entry"
    )

    # Every raw field must be preserved in each enriched record
    for raw, enriched in zip(raw_stale, results):
        for key, value in raw.items():
            assert enriched.get(key) == value, (
                f"Field '{key}' mismatch: raw={value!r}, enriched={enriched.get(key)!r}"
            )

    # Enrichment fields must be present and correct
    for enriched in results:
        assert enriched["class_label"] == "stale"
        assert enriched["proposed_remediation"] == "re-sync or close"

    # audit_bridge_mappings raw records must NOT be mutated (no enrichment fields)
    for raw in raw_stale:
        assert "class_label" not in raw, (
            "audit_bridge_mappings stale records must not be mutated"
        )
        assert "proposed_remediation" not in raw, (
            "audit_bridge_mappings stale records must not be mutated"
        )


def test_enumerate_stale_cli_backward_compat(
    fsck: ModuleType, capsys: pytest.CaptureFixture
) -> None:
    """CLI report output is byte-identical before and after adding enumerate_stale_anomalies."""
    now_ns = time.time_ns()
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_stale_ticket(
            tracker,
            ticket_id="ticket-cli-0001",
            jira_key="CLI-1",
            now_ns=now_ns,
        )

        # Run CLI main() with explicit tracker path and now_ts
        exit_code = fsck.main(
            [
                f"--tickets-tracker={tracker}",
                f"--now-ts={now_ns}",
            ]
        )

        captured = capsys.readouterr()

        # Verify the raw audit result is still the correct shape (not mutated)
        # Must be inside the `with` block so the tracker dir still exists.
        findings = fsck.audit_bridge_mappings(tracker, now_ts=now_ns)
        assert set(findings.keys()) == {"orphaned", "duplicates", "stale"}, (
            "audit_bridge_mappings must still return exactly three keys"
        )
        stale_keys = set(findings["stale"][0].keys())
        assert stale_keys == {"ticket_id", "jira_key", "last_sync_ts"}, (
            f"audit_bridge_mappings stale record must not gain extra keys: {stale_keys}"
        )

    # Should exit 1 (issues found)
    assert exit_code == 1, f"Expected exit code 1 (issues found), got {exit_code}"

    # Report must mention the stale ticket
    assert "ticket-cli-0001" in captured.out, (
        "CLI report must include the stale ticket_id"
    )
    assert "CLI-1" in captured.out, "CLI report must include the jira_key"
    assert "Stale SYNCs: 1" in captured.out, "CLI report must show stale count"
