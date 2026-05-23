"""Unit tests for enumerate_duplicate_anomalies() in ticket-bridge-fsck.py.

Tests cover:
  - test_enumerate_duplicates_returns_list: seeded duplicate set returns list
    of length 1.
  - test_enumerate_duplicates_record_shape: record has jira_key, ticket_ids,
    class_label, proposed_remediation, keeper, and closees.
  - test_enumerate_duplicates_matches_audit_output: enriched records correspond
    to raw audit_bridge_mappings()['duplicates'] output plus enrichment fields.
  - test_enumerate_duplicates_cli_backward_compat: CLI output is unchanged
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


def _write_event(ticket_dir: Path, filename: str, payload: dict) -> None:
    ticket_dir.mkdir(parents=True, exist_ok=True)
    (ticket_dir / filename).write_text(json.dumps(payload))


def _seed_duplicate_tickets(
    tracker: Path,
    jira_key: str = "TEST-42",
    ticket_id_a: str = "ticket-dup-0001",
    ticket_id_b: str = "ticket-dup-0002",
) -> None:
    """Create two ticket directories that both claim the same jira_key via SYNC.

    Both tickets have CREATE events so they are not orphans; they are duplicates
    because two distinct local tickets map to the same Jira issue key.
    """
    now_ns = time.time_ns()
    for ticket_id in (ticket_id_a, ticket_id_b):
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
                "timestamp": now_ns,
            },
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_enumerate_duplicates_returns_list(fsck: ModuleType) -> None:
    """Seeded duplicate set returns a list of exactly one record."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_duplicate_tickets(tracker)

        results = fsck.enumerate_duplicate_anomalies(tracker)

    assert isinstance(results, list), "enumerate_duplicate_anomalies must return a list"
    assert len(results) == 1, f"Expected 1 duplicate record, got {len(results)}"


def test_enumerate_duplicates_record_shape(fsck: ModuleType) -> None:
    """Each record has jira_key, ticket_ids, class_label, proposed_remediation, keeper, closees."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_duplicate_tickets(
            tracker,
            jira_key="SHAPE-99",
            ticket_id_a="ticket-shape-a",
            ticket_id_b="ticket-shape-b",
        )

        results = fsck.enumerate_duplicate_anomalies(tracker)

    assert len(results) == 1
    record = results[0]

    # Core fields from raw audit record
    assert record["jira_key"] == "SHAPE-99", (
        f"Expected jira_key='SHAPE-99', got {record['jira_key']!r}"
    )
    assert isinstance(record["ticket_ids"], list), "ticket_ids must be a list"
    assert set(record["ticket_ids"]) == {"ticket-shape-a", "ticket-shape-b"}, (
        f"ticket_ids mismatch: {record['ticket_ids']}"
    )

    # Enrichment fields
    assert "class_label" in record, "record missing 'class_label'"
    assert record["class_label"] == "duplicate", (
        f"class_label must be 'duplicate', got {record['class_label']!r}"
    )

    assert "proposed_remediation" in record, "record missing 'proposed_remediation'"
    assert record["proposed_remediation"] == "close newer duplicates", (
        f"proposed_remediation must be 'close newer duplicates', "
        f"got {record['proposed_remediation']!r}"
    )

    assert "keeper" in record, "record missing 'keeper'"
    assert record["keeper"] in record["ticket_ids"], (
        f"keeper must be one of ticket_ids, got {record['keeper']!r}"
    )
    assert record["keeper"] == record["ticket_ids"][0], (
        "keeper must be ticket_ids[0] (oldest)"
    )

    assert "closees" in record, "record missing 'closees'"
    assert isinstance(record["closees"], list), "closees must be a list"
    assert record["closees"] == record["ticket_ids"][1:], (
        f"closees must be ticket_ids[1:], got {record['closees']!r}"
    )


def test_enumerate_duplicates_matches_audit_output(fsck: ModuleType) -> None:
    """Returned entries correspond to audit_bridge_mappings['duplicates'] plus enrichment fields."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_duplicate_tickets(
            tracker,
            jira_key="AUDIT-77",
            ticket_id_a="ticket-audit-a",
            ticket_id_b="ticket-audit-b",
        )

        audit = fsck.audit_bridge_mappings(tracker)
        results = fsck.enumerate_duplicate_anomalies(tracker)

    raw_duplicates = audit["duplicates"]
    assert len(results) == len(raw_duplicates), (
        "enumerate_duplicate_anomalies must return one record per raw duplicate entry"
    )

    # Every raw field must be preserved in each enriched record
    for raw, enriched in zip(raw_duplicates, results):
        for key, value in raw.items():
            assert enriched.get(key) == value, (
                f"Field '{key}' mismatch: raw={value!r}, enriched={enriched.get(key)!r}"
            )

    # Enrichment fields must be present and correct
    for enriched in results:
        assert enriched["class_label"] == "duplicate"
        assert enriched["proposed_remediation"] == "close newer duplicates"
        assert enriched["keeper"] == enriched["ticket_ids"][0]
        assert enriched["closees"] == enriched["ticket_ids"][1:]

    # audit_bridge_mappings raw records must NOT be mutated (no enrichment fields)
    for raw in raw_duplicates:
        assert "class_label" not in raw, (
            "audit_bridge_mappings duplicate records must not be mutated"
        )
        assert "proposed_remediation" not in raw, (
            "audit_bridge_mappings duplicate records must not be mutated"
        )
        assert "keeper" not in raw, (
            "audit_bridge_mappings duplicate records must not gain 'keeper'"
        )
        assert "closees" not in raw, (
            "audit_bridge_mappings duplicate records must not gain 'closees'"
        )


def test_enumerate_duplicates_cli_backward_compat(
    fsck: ModuleType, capsys: pytest.CaptureFixture
) -> None:
    """CLI report output is unchanged after adding enumerate_duplicate_anomalies."""
    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        _seed_duplicate_tickets(
            tracker,
            jira_key="CLI-42",
            ticket_id_a="ticket-cli-a",
            ticket_id_b="ticket-cli-b",
        )

        # Run CLI main() with explicit tracker path
        exit_code = fsck.main([f"--tickets-tracker={tracker}"])

        captured = capsys.readouterr()

        # Verify the raw audit result is still the correct shape (not mutated)
        findings = fsck.audit_bridge_mappings(tracker)
        assert set(findings.keys()) == {"orphaned", "duplicates", "stale"}, (
            "audit_bridge_mappings must still return exactly three keys"
        )
        dup_keys = set(findings["duplicates"][0].keys())
        assert dup_keys == {"jira_key", "ticket_ids"}, (
            f"audit_bridge_mappings duplicate record must not gain extra keys: {dup_keys}"
        )

    # Should exit 1 (issues found)
    assert exit_code == 1, f"Expected exit code 1 (issues found), got {exit_code}"

    # Report must mention the duplicate jira_key
    assert "CLI-42" in captured.out, "CLI report must include the jira_key"
    assert "Duplicates: 1" in captured.out, "CLI report must show duplicate count"
