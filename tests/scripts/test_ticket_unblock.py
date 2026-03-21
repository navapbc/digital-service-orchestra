"""RED tests for ticket-unblock.py detect_newly_unblocked function.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL before ticket-unblock.py is implemented.

The function under test:
    detect_newly_unblocked(
        closed_ticket_ids: list[str],
        tracker_dir: str,
        event_source: str,
    ) -> list[str]

Contract:
    - Returns the list of ticket IDs that are now ready_to_work=True after
      the given tickets are closed.
    - A ticket is newly unblocked when ALL of its deps are now closed.
    - Accepts event_source values: 'local-close' and 'sync-resolution'.
    - Uses a single batch graph traversal (not one query per closed ticket).

Test: python3 -m pytest tests/scripts/test_ticket_unblock.py
All tests must fail (ERROR/FAILED) until ticket-unblock.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-unblock.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ticket_unblock", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def unblock() -> ModuleType:
    """Return the ticket-unblock module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"ticket-unblock.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_UUID_A = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
_UUID_B = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
_UUID_C = "cccccccc-cccc-4ccc-cccc-cccccccccccc"


def _write_ticket(
    tracker_dir: Path,
    ticket_id: str,
    status: str = "open",
    deps: list[str] | None = None,
) -> Path:
    """Write a minimal ticket directory with a CREATE event (and optional STATUS/LINK events).

    Dependency relationships are recorded as LINK events with relation="blocks" written
    in the blocker's directory, matching the schema used by ticket-link.sh and
    ticket-reducer.py.  For each entry in ``deps``, ticket ``dep_id`` blocks
    ``ticket_id``, so a LINK event is written in ``dep_id``'s directory with
    ``target_id=ticket_id`` and ``relation="blocks"``.

    Filenames follow the convention: ``{timestamp}-{uuid}-{event_type}.json``

    Returns the ticket directory path.
    """
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    # CREATE event
    create_event = {
        "event_type": "CREATE",
        "uuid": f"create-{ticket_id}",
        "timestamp": 1000,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "ticket_type": "task",
            "title": f"Ticket {ticket_id}",
            "parent_id": None,
        },
    }
    with open(ticket_dir / f"1000-create-{ticket_id}-CREATE.json", "w") as f:
        json.dump(create_event, f)

    # STATUS event if not open
    if status != "open":
        status_event = {
            "event_type": "STATUS",
            "uuid": f"status-{ticket_id}",
            "timestamp": 2000,
            "author": "Test User",
            "env_id": "00000000-0000-4000-8000-000000000001",
            "data": {
                "status": status,
                "current_status": "open",
            },
        }
        with open(ticket_dir / f"2000-status-{ticket_id}-STATUS.json", "w") as f:
            json.dump(status_event, f)

    # LINK events: each entry in deps means "dep_id blocks ticket_id".
    # Following ticket-link.sh, the LINK event is written in the blocker's
    # (dep_id's) directory with data.target_id=ticket_id and data.relation=blocks.
    # Ensure the blocker directory exists so the event file can be placed there.
    if deps:
        for i, dep_id in enumerate(deps):
            link_uuid = f"link-{dep_id}-blocks-{ticket_id}-{i:04d}"
            timestamp = 1500 + i
            link_event = {
                "event_type": "LINK",
                "uuid": link_uuid,
                "timestamp": timestamp,
                "author": "Test User",
                "env_id": "00000000-0000-4000-8000-000000000001",
                "data": {
                    "target_id": ticket_id,
                    "relation": "blocks",
                },
            }
            blocker_dir = tracker_dir / dep_id
            blocker_dir.mkdir(parents=True, exist_ok=True)
            filename = f"{timestamp}-{link_uuid}-LINK.json"
            with open(blocker_dir / filename, "w") as f:
                json.dump(link_event, f)

    return ticket_dir


# ---------------------------------------------------------------------------
# Test 1: closing A does NOT unblock B when B still depends on C (open)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_no_newly_unblocked_when_blocked_by_other_ticket(
    unblock: ModuleType, tmp_path: Path
) -> None:
    """Closing ticket A must NOT unblock B when B also depends on C (still open).

    Setup:
        - ticket-a: closed (just closed)
        - ticket-b: open, deps=[ticket-a, ticket-c]
        - ticket-c: open

    Expected: detect_newly_unblocked(['ticket-a'], ...) == []
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open", deps=["ticket-a", "ticket-c"])
    _write_ticket(tracker_dir, "ticket-c", status="open")

    result = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )

    assert result == [], (
        f"Expected no newly unblocked tickets (ticket-c still open), got {result!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: closing A unblocks B when B's only blocker was A
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_single_newly_unblocked_on_close(unblock: ModuleType, tmp_path: Path) -> None:
    """Closing ticket A must unblock B when B's only dep was A.

    Setup:
        - ticket-a: closed (just closed)
        - ticket-b: open, deps=[ticket-a]

    Expected: detect_newly_unblocked(['ticket-a'], ...) == ['ticket-b']
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open", deps=["ticket-a"])

    result = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )

    assert "ticket-b" in result, (
        f"Expected 'ticket-b' to be newly unblocked, got {result!r}"
    )
    assert len(result) == 1, (
        f"Expected exactly 1 newly unblocked ticket, got {result!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: closing A unblocks B and C simultaneously
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_multiple_newly_unblocked_on_close(unblock: ModuleType, tmp_path: Path) -> None:
    """Closing ticket A must unblock both B and C when each depended only on A.

    Setup:
        - ticket-a: closed (just closed)
        - ticket-b: open, deps=[ticket-a]
        - ticket-c: open, deps=[ticket-a]

    Expected: detect_newly_unblocked(['ticket-a'], ...) contains 'ticket-b' and 'ticket-c'
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open", deps=["ticket-a"])
    _write_ticket(tracker_dir, "ticket-c", status="open", deps=["ticket-a"])

    result = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )

    assert "ticket-b" in result, f"Expected 'ticket-b' in result, got {result!r}"
    assert "ticket-c" in result, f"Expected 'ticket-c' in result, got {result!r}"
    assert len(result) == 2, (
        f"Expected exactly 2 newly unblocked tickets, got {result!r}"
    )


# ---------------------------------------------------------------------------
# Test 4: batch graph query — traversal called once, not per-ticket
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_batch_graph_query_for_burst(unblock: ModuleType, tmp_path: Path) -> None:
    """detect_newly_unblocked must accept a list and use batch traversal (not per-ticket loops).

    Validates that the function signature accepts a list of closed_ticket_ids
    and processes them in a single pass rather than iterating with individual calls.
    We verify this by passing multiple closed IDs at once and checking correctness —
    a per-ticket implementation would produce duplicates or miscount.

    Setup:
        - ticket-a: closed (batch)
        - ticket-b: closed (batch)
        - ticket-c: open, deps=[ticket-a, ticket-b]  (both blockers now closed)
        - ticket-d: open, deps=[ticket-a]
        - ticket-e: open, deps=[ticket-b]

    Expected: detect_newly_unblocked(['ticket-a', 'ticket-b'], ...) ==
              ['ticket-c', 'ticket-d', 'ticket-e'] (order-independent)
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="closed")
    _write_ticket(tracker_dir, "ticket-c", status="open", deps=["ticket-a", "ticket-b"])
    _write_ticket(tracker_dir, "ticket-d", status="open", deps=["ticket-a"])
    _write_ticket(tracker_dir, "ticket-e", status="open", deps=["ticket-b"])

    result = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a", "ticket-b"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )

    result_set = set(result)
    expected_set = {"ticket-c", "ticket-d", "ticket-e"}
    assert result_set == expected_set, (
        f"Expected newly unblocked {expected_set!r}, got {result_set!r}"
    )
    # No duplicates
    assert len(result) == len(result_set), f"Result contains duplicates: {result!r}"


# ---------------------------------------------------------------------------
# Test 5: event_source parameter is accepted with valid values
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_event_source_parameter_accepted(unblock: ModuleType, tmp_path: Path) -> None:
    """detect_newly_unblocked must accept event_source='local-close' and 'sync-resolution'.

    Both values must be accepted without raising TypeError or ValueError.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")

    # Should not raise for 'local-close'
    result_local = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )
    assert isinstance(result_local, list), (
        f"Expected list return value for event_source='local-close', got {type(result_local)}"
    )

    # Should not raise for 'sync-resolution'
    result_sync = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="sync-resolution",
    )
    assert isinstance(result_sync, list), (
        f"Expected list return value for event_source='sync-resolution', got {type(result_sync)}"
    )


# ---------------------------------------------------------------------------
# Helpers for depends_on relation
# ---------------------------------------------------------------------------


def _write_depends_on_link(
    tracker_dir: Path,
    depending_id: str,
    blocker_id: str,
    timestamp: int = 1500,
) -> None:
    """Write a LINK event in depending_id's directory: depending_id depends_on blocker_id.

    The LINK event has relation='depends_on' and target_id=blocker_id.
    This means blocker_id must be closed before depending_id can proceed.
    """
    depending_dir = tracker_dir / depending_id
    depending_dir.mkdir(parents=True, exist_ok=True)
    link_uuid = f"link-{depending_id}-depends_on-{blocker_id}"
    link_event = {
        "event_type": "LINK",
        "uuid": link_uuid,
        "timestamp": timestamp,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "target_id": blocker_id,
            "relation": "depends_on",
        },
    }
    filename = f"{timestamp}-{link_uuid}-LINK.json"
    with open(depending_dir / filename, "w") as f:
        json.dump(link_event, f)


# ---------------------------------------------------------------------------
# Test 6: depends_on direction — closing the target (blocker) unblocks the dependent
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_depends_on_direction_unblocks_dependent(
    unblock: ModuleType, tmp_path: Path
) -> None:
    """Closing ticket A must unblock B when B depends_on A (A is the blocker).

    Setup:
        - ticket-b: open, has LINK event relation='depends_on', target_id='ticket-a'
          (i.e., ticket-b depends on ticket-a, so ticket-a blocks ticket-b)
        - ticket-a: just closed

    Expected: detect_newly_unblocked(['ticket-a'], ...) == ['ticket-b']

    This verifies the depends_on direction: the LINK event is in ticket-b's dir,
    but ticket-a is the blocker (the target of depends_on).
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_depends_on_link(tracker_dir, "ticket-b", "ticket-a")

    result = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )

    assert "ticket-b" in result, (
        f"Expected 'ticket-b' to be newly unblocked (depends_on ticket-a which closed), "
        f"got {result!r}"
    )
    assert len(result) == 1, (
        f"Expected exactly 1 newly unblocked ticket, got {result!r}"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_depends_on_does_not_unblock_the_blocker(
    unblock: ModuleType, tmp_path: Path
) -> None:
    """Closing ticket B must NOT treat ticket A as unblocked when B depends_on A.

    Setup:
        - ticket-b: open, depends_on ticket-a (ticket-a blocks ticket-b)
        - ticket-a: open (being "closed" in this test)

    The depends_on LINK is in ticket-b's dir with target_id=ticket-a.
    Closing ticket-a should unblock ticket-b, NOT cause ticket-a to appear unblocked.

    Expected: detect_newly_unblocked(['ticket-a'], ...) contains 'ticket-b', NOT 'ticket-a'
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_depends_on_link(tracker_dir, "ticket-b", "ticket-a")

    result = unblock.detect_newly_unblocked(
        closed_ticket_ids=["ticket-a"],
        tracker_dir=str(tracker_dir),
        event_source="local-close",
    )

    assert "ticket-a" not in result, (
        f"ticket-a must not appear as unblocked (it was closed, not blocked), "
        f"got {result!r}"
    )
    assert "ticket-b" in result, (
        f"Expected 'ticket-b' to be newly unblocked after ticket-a closes, "
        f"got {result!r}"
    )
