"""Unit tests for enumerate_open_count_skew_anomalies() in ticket-bridge-fsck.py.

Tests cover:
  - test_enumerate_returns_non_zero_delta_types: mock AcliClient returns different
    counts per type; verify only non-zero-delta types returned.
  - test_enumerate_returns_empty_when_no_skew: all counts match -> empty list.
  - test_enumerate_local_count_uses_open_status: local tickets with status="closed"
    not counted as open.
  - test_enumerate_handles_missing_tickets_dir: tickets_dir does not exist ->
    returns empty list (or handles gracefully).
  - test_enumerate_delta_calculation: delta = local_open - jira_open.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import types
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

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
        pytest.fail(f"ticket-bridge-fsck.py not found at {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_event(ticket_dir: Path, filename: str, payload: dict) -> None:
    ticket_dir.mkdir(parents=True, exist_ok=True)
    (ticket_dir / filename).write_text(json.dumps(payload))


def _seed_ticket(
    tracker: Path,
    ticket_id: str,
    ticket_type: str,
    status: str = "open",
) -> None:
    """Create a local ticket with CREATE and STATUS events."""
    ticket_dir = tracker / ticket_id
    _write_event(
        ticket_dir,
        "0001-CREATE.json",
        {"event_type": "CREATE", "ticket_id": ticket_id, "type": ticket_type},
    )
    _write_event(
        ticket_dir,
        "0002-STATUS.json",
        {"event_type": "STATUS", "ticket_id": ticket_id, "status": status},
    )


def _make_mock_client(counts_by_type: dict[str, int]) -> MagicMock:
    """Build a mock AcliClient whose search_issues returns a list of the given length."""
    client = MagicMock()

    def _search(jql: str, **kwargs) -> list:
        for ttype, count in counts_by_type.items():
            if f"issuetype = {ttype}" in jql:
                return [{}] * count
        return []

    client.search_issues.side_effect = _search
    return client


def _patch_acli_client(mock_client: MagicMock):
    """Context manager that intercepts the importlib load inside enumerate_open_count_skew_anomalies.

    The function uses ``importlib.util.spec_from_file_location`` to load
    acli-integration.py from disk.  We intercept this by patching
    ``importlib.util.spec_from_file_location`` to return a fake spec whose
    loader installs a synthetic module with ``AcliClient`` set to a factory
    that returns mock_client.
    """

    # Build a synthetic acli_integration module with a mock AcliClient class
    fake_mod = types.ModuleType("acli_integration")
    fake_mod.AcliClient = MagicMock(return_value=mock_client)  # type: ignore[attr-defined]

    # Build a fake ModuleSpec whose loader sets attrs on the module
    fake_spec = MagicMock()
    fake_spec.loader = MagicMock()

    def _exec_module(mod):
        mod.__dict__.update(fake_mod.__dict__)
        mod.AcliClient = fake_mod.AcliClient  # type: ignore[attr-defined]

    fake_spec.loader.exec_module.side_effect = _exec_module

    original_spec_from_file_location = importlib.util.spec_from_file_location

    def _fake_spec_from_file_location(name, path, **kwargs):
        if name == "acli_integration":
            return fake_spec
        return original_spec_from_file_location(name, path, **kwargs)

    return patch(
        "importlib.util.spec_from_file_location",
        side_effect=_fake_spec_from_file_location,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_enumerate_returns_non_zero_delta_types(fsck: ModuleType) -> None:
    """Only types where local_open != jira_open appear in the result."""
    # Jira counts: epic=3, story=0, task=1, bug=2
    mock_client = _make_mock_client({"epic": 3, "story": 0, "task": 1, "bug": 2})

    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        # Local open: epic=3 (matches), story=1 (skew), task=1 (matches), bug=0 (skew)
        for i in range(3):
            _seed_ticket(tracker, f"epic-{i:04d}", "epic", "open")
        _seed_ticket(tracker, "story-0001", "story", "open")
        _seed_ticket(tracker, "task-0001", "task", "open")
        # bug: no local open tickets → local=0, jira=2 → delta=-2

        with _patch_acli_client(mock_client):
            results = fsck.enumerate_open_count_skew_anomalies(tracker)

    result_types = {r["type"] for r in results}
    assert "epic" not in result_types, "epic matches — must not appear"
    assert "task" not in result_types, "task matches — must not appear"
    assert "story" in result_types, "story has skew (local=1, jira=0) — must appear"
    assert "bug" in result_types, "bug has skew (local=0, jira=2) — must appear"


def test_enumerate_returns_empty_when_no_skew(fsck: ModuleType) -> None:
    """When all local counts equal Jira counts, result is an empty list."""
    # Jira: epic=1, story=1, task=1, bug=1
    mock_client = _make_mock_client({"epic": 1, "story": 1, "task": 1, "bug": 1})

    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        # Seed exactly 1 open ticket of each type
        _seed_ticket(tracker, "epic-0001", "epic", "open")
        _seed_ticket(tracker, "story-0001", "story", "open")
        _seed_ticket(tracker, "task-0001", "task", "open")
        _seed_ticket(tracker, "bug-0001", "bug", "open")

        with _patch_acli_client(mock_client):
            results = fsck.enumerate_open_count_skew_anomalies(tracker)

    assert results == [], f"Expected empty list when counts match, got {results}"


def test_enumerate_local_count_uses_open_status(fsck: ModuleType) -> None:
    """Tickets with status='closed' are NOT counted as local open."""
    # Jira: story=0 → if closed local tickets were counted, delta would be non-zero
    mock_client = _make_mock_client({"epic": 0, "story": 0, "task": 0, "bug": 0})

    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        # Two stories, both closed locally — local_open should be 0 for story
        _seed_ticket(tracker, "story-closed-0001", "story", "closed")
        _seed_ticket(tracker, "story-closed-0002", "story", "closed")

        with _patch_acli_client(mock_client):
            results = fsck.enumerate_open_count_skew_anomalies(tracker)

    # local_open(story)=0, jira_open(story)=0 → delta=0 → not in results
    story_results = [r for r in results if r["type"] == "story"]
    assert story_results == [], (
        f"Closed tickets must not be counted as open; story results: {story_results}"
    )


def test_enumerate_handles_missing_tickets_dir(fsck: ModuleType) -> None:
    """When tickets_dir does not exist, all local counts are 0.

    If Jira also returns 0 for all types, result is an empty list.
    """
    # All Jira counts = 0 so delta = 0 for every type → empty result
    mock_client = _make_mock_client({"epic": 0, "story": 0, "task": 0, "bug": 0})

    nonexistent = Path("/tmp/definitely-does-not-exist-84b3-5fe4")

    with _patch_acli_client(mock_client):
        results = fsck.enumerate_open_count_skew_anomalies(nonexistent)

    assert isinstance(results, list), "Must return a list even for missing tickets_dir"
    assert results == [], f"All counts 0 → no skew expected, got {results}"


def test_enumerate_delta_calculation(fsck: ModuleType) -> None:
    """delta = local_open - jira_open for each type."""
    # Jira: epic=5, story=2, task=3, bug=1
    mock_client = _make_mock_client({"epic": 5, "story": 2, "task": 3, "bug": 1})

    with tempfile.TemporaryDirectory() as tmp:
        tracker = Path(tmp)
        # Local open: epic=3, story=4, task=3 (matches), bug=0
        for i in range(3):
            _seed_ticket(tracker, f"epic-{i:04d}", "epic", "open")
        for i in range(4):
            _seed_ticket(tracker, f"story-{i:04d}", "story", "open")
        for i in range(3):
            _seed_ticket(tracker, f"task-{i:04d}", "task", "open")
        # bug: 0 local open

        with _patch_acli_client(mock_client):
            results = fsck.enumerate_open_count_skew_anomalies(tracker)

    results_by_type = {r["type"]: r for r in results}

    # task matches (3==3) → not in results
    assert "task" not in results_by_type, "task count matches — should not appear"

    # epic: local=3, jira=5, delta=-2
    assert "epic" in results_by_type
    epic = results_by_type["epic"]
    assert epic["local_open"] == 3
    assert epic["jira_open"] == 5
    assert epic["delta"] == 3 - 5  # -2

    # story: local=4, jira=2, delta=2
    assert "story" in results_by_type
    story = results_by_type["story"]
    assert story["local_open"] == 4
    assert story["jira_open"] == 2
    assert story["delta"] == 4 - 2  # 2

    # bug: local=0, jira=1, delta=-1
    assert "bug" in results_by_type
    bug = results_by_type["bug"]
    assert bug["local_open"] == 0
    assert bug["jira_open"] == 1
    assert bug["delta"] == 0 - 1  # -1
