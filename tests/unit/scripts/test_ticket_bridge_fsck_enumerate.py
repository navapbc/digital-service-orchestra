"""Unit tests for enumerate_orphan_anomalies() in ticket-bridge-fsck.py.

Tests cover:
  - test_enumerate_returns_structured_records: seeded orphan returns enriched
    records with class_label, side, and proposed_remediation fields.
  - test_cli_backward_compatible: audit_bridge_mappings() still returns the
    original dict shape with 'orphaned', 'duplicates', and 'stale' keys.
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


def _write_event(ticket_dir: Path, filename: str, payload: dict) -> None:
    ticket_dir.mkdir(parents=True, exist_ok=True)
    (ticket_dir / filename).write_text(json.dumps(payload))


def _seed_orphan_ticket(
    tracker: Path,
    ticket_id: str = "jira-test-0001",
    jira_key: str = "TEST-1",
) -> None:
    """Create a ticket directory with a SYNC event but NO CREATE event (orphan)."""
    ticket_dir = tracker / ticket_id
    _write_event(
        ticket_dir,
        "0001-SYNC.json",
        {
            "event_type": "SYNC",
            "ticket_id": ticket_id,
            "jira_key": jira_key,
            "timestamp": time.time_ns(),
        },
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_enumerate_returns_structured_records(fsck: ModuleType) -> None:
    """Seeded orphan produces an enriched record with all required contract fields."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_orphan_ticket(tracker, ticket_id="jira-test-0001", jira_key="TEST-1")

        results = fsck.enumerate_orphan_anomalies(tracker)

    assert len(results) == 1, "Expected exactly one orphan record"
    record = results[0]

    # Core identity fields
    assert record["ticket_id"] == "jira-test-0001"
    assert record["jira_key"] == "TEST-1"

    # Enrichment fields
    assert "class_label" in record, "record missing 'class_label'"
    assert record["class_label"], "class_label must be non-empty"

    assert "side" in record, "record missing 'side'"
    assert record["side"], "side must be non-empty"

    assert "proposed_remediation" in record, "record missing 'proposed_remediation'"
    assert record["proposed_remediation"], "proposed_remediation must be non-empty"


def test_enumerate_class_label_is_orphan(fsck: ModuleType) -> None:
    """class_label field is exactly 'orphan'."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_orphan_ticket(tracker)

        results = fsck.enumerate_orphan_anomalies(tracker)

    assert results[0]["class_label"] == "orphan"


def test_enumerate_side_is_local_only(fsck: ModuleType) -> None:
    """side field is 'local-only' for SYNC-without-CREATE orphans."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_orphan_ticket(tracker)

        results = fsck.enumerate_orphan_anomalies(tracker)

    assert results[0]["side"] == "local-only"


def test_enumerate_empty_when_no_orphans(fsck: ModuleType) -> None:
    """Returns empty list when no orphan anomalies exist."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        # Create a ticket with both CREATE and SYNC (not an orphan)
        ticket_dir = tracker / "ticket-0001"
        _write_event(
            ticket_dir,
            "0001-CREATE.json",
            {"event_type": "CREATE", "ticket_id": "ticket-0001"},
        )
        _write_event(
            ticket_dir,
            "0002-SYNC.json",
            {
                "event_type": "SYNC",
                "ticket_id": "ticket-0001",
                "jira_key": "PROJ-1",
                "timestamp": time.time_ns(),
            },
        )

        results = fsck.enumerate_orphan_anomalies(tracker)

    assert results == []


def test_cli_backward_compatible(fsck: ModuleType) -> None:
    """audit_bridge_mappings() still returns the original three-key dict shape."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_orphan_ticket(tracker)

        findings = fsck.audit_bridge_mappings(tracker)

    # Shape must remain unchanged
    assert set(findings.keys()) == {
        "orphaned",
        "duplicates",
        "stale",
    }, f"Unexpected keys in audit_bridge_mappings result: {set(findings.keys())}"

    # Original orphan records must NOT have been mutated (no enrichment fields)
    assert len(findings["orphaned"]) == 1
    original_keys = set(findings["orphaned"][0].keys())
    assert original_keys == {
        "ticket_id",
        "jira_key",
    }, f"audit_bridge_mappings orphan record gained unexpected keys: {original_keys}"
