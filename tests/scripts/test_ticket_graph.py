"""RED tests for ticket-graph.py.

These tests are RED — they test functionality that does not yet exist.
All test functions MUST FAIL before ticket-graph.py is implemented.

The module under test is expected to expose:
    build_dep_graph(ticket_id: str, tracker_dir: str) -> dict
    add_dependency(source_id: str, target_id: str, tracker_dir: str) -> None
    CyclicDependencyError (exception class)

Contract:
  - build_dep_graph returns:
        {"ticket_id": str, "deps": list, "ready_to_work": bool, "blockers": list}
  - ready_to_work=True when all direct blockers are closed (or tombstoned)
  - add_dependency raises CyclicDependencyError for cycles (direct or transitive)
  - Missing blocker directories (archived/tombstoned) are treated as closed
  - .tombstone.json with {"status": "closed"} in a blocker dir → treated as closed
  - Graph results are cached; cache is invalidated when a new LINK event is added

Test: python3 -m pytest tests/scripts/test_ticket_graph.py -x
All tests must return non-zero until ticket-graph.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
import time
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-graph.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ticket_graph", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def graph() -> ModuleType:
    """Return the ticket-graph module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"ticket-graph.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_UUID_A = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
_UUID_B = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
_UUID_C = "cccccccc-cccc-4ccc-cccc-cccccccccccc"
_UUID_D = "dddddddd-dddd-4ddd-dddd-dddddddddddd"


def _write_ticket(
    tracker_dir: Path,
    ticket_id: str,
    status: str = "open",
) -> Path:
    """Write a minimal ticket directory with a CREATE event and optional STATUS event.

    Returns the ticket directory path.
    """
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

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

    return ticket_dir


def _write_blocks_link(
    tracker_dir: Path,
    blocker_id: str,
    blocked_id: str,
    link_uuid: str | None = None,
    timestamp: int = 1500,
) -> None:
    """Write a LINK event in blocker_id's directory: blocker_id blocks blocked_id.

    Follows the schema used by ticket-link.sh: LINK event is stored in the
    blocker's directory with data.target_id=blocked_id and data.relation='blocks'.
    """
    if link_uuid is None:
        link_uuid = f"link-{blocker_id}-blocks-{blocked_id}"
    blocker_dir = tracker_dir / blocker_id
    blocker_dir.mkdir(parents=True, exist_ok=True)
    link_event = {
        "event_type": "LINK",
        "uuid": link_uuid,
        "timestamp": timestamp,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "target_id": blocked_id,
            "relation": "blocks",
        },
    }
    filename = f"{timestamp}-{link_uuid}-LINK.json"
    with open(blocker_dir / filename, "w") as f:
        json.dump(link_event, f)


# ---------------------------------------------------------------------------
# Graph traversal & ready_to_work
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_ready_to_work_all_blockers_closed(
    graph: ModuleType, tmp_path: Path
) -> None:
    """Ticket B is ready_to_work=True when its only blocker (A) is closed.

    Setup:
        - ticket-a: closed (blocks ticket-b)
        - ticket-b: open

    Expected: build_dep_graph('ticket-b', tracker_dir)['ready_to_work'] == True
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b")

    result = graph.build_dep_graph("ticket-b", str(tracker_dir))

    assert result["ready_to_work"] is True, (
        f"Expected ready_to_work=True (blocker ticket-a is closed), got {result!r}"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_ready_to_work_blocker_still_open(
    graph: ModuleType, tmp_path: Path
) -> None:
    """Ticket B is ready_to_work=False when its blocker (A) is still open.

    Setup:
        - ticket-a: open (blocks ticket-b)
        - ticket-b: open

    Expected: build_dep_graph('ticket-b', tracker_dir)['ready_to_work'] == False
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b")

    result = graph.build_dep_graph("ticket-b", str(tracker_dir))

    assert result["ready_to_work"] is False, (
        f"Expected ready_to_work=False (blocker ticket-a is still open), got {result!r}"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_ready_to_work_direct_blockers_only(
    graph: ModuleType, tmp_path: Path
) -> None:
    """Ticket B is ready_to_work=False when at least one direct blocker is open.

    Setup:
        - ticket-a: open  (blocks ticket-b)
        - ticket-c: closed (blocks ticket-b)
        - ticket-b: open

    Expected: ready_to_work=False because ticket-a (direct blocker) is still open.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_ticket(tracker_dir, "ticket-c", status="closed")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b", timestamp=1500)
    _write_blocks_link(tracker_dir, "ticket-c", "ticket-b", timestamp=1501)

    result = graph.build_dep_graph("ticket-b", str(tracker_dir))

    assert result["ready_to_work"] is False, (
        f"Expected ready_to_work=False (ticket-a still open), got {result!r}"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_deps_output_schema(graph: ModuleType, tmp_path: Path) -> None:
    """build_dep_graph returns the expected output schema.

    Expected keys: ticket_id, deps, ready_to_work, blockers
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b")

    result = graph.build_dep_graph("ticket-b", str(tracker_dir))

    assert isinstance(result, dict), f"Expected dict, got {type(result)}"
    assert "ticket_id" in result, f"Missing 'ticket_id' key in {result!r}"
    assert "deps" in result, f"Missing 'deps' key in {result!r}"
    assert "ready_to_work" in result, f"Missing 'ready_to_work' key in {result!r}"
    assert "blockers" in result, f"Missing 'blockers' key in {result!r}"
    assert result["ticket_id"] == "ticket-b", (
        f"Expected ticket_id='ticket-b', got {result['ticket_id']!r}"
    )
    assert isinstance(result["ready_to_work"], bool), (
        f"ready_to_work must be bool, got {type(result['ready_to_work'])}"
    )
    assert isinstance(result["deps"], list), (
        f"deps must be list, got {type(result['deps'])}"
    )
    assert isinstance(result["blockers"], list), (
        f"blockers must be list, got {type(result['blockers'])}"
    )


# ---------------------------------------------------------------------------
# Cycle detection
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_cycle_detection_rejects_direct_cycle(
    graph: ModuleType, tmp_path: Path
) -> None:
    """add_dependency raises CyclicDependencyError for a direct cycle A→B, B→A.

    Setup: ticket-a blocks ticket-b already exists.
    Action: add_dependency('ticket-b', 'ticket-a', ...) must raise CyclicDependencyError.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b")

    with pytest.raises(graph.CyclicDependencyError):
        graph.add_dependency("ticket-b", "ticket-a", str(tracker_dir))


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_cycle_detection_rejects_transitive_cycle(
    graph: ModuleType, tmp_path: Path
) -> None:
    """add_dependency raises CyclicDependencyError for a transitive cycle A→B→C→A.

    Setup: ticket-a blocks ticket-b, ticket-b blocks ticket-c.
    Action: add_dependency('ticket-c', 'ticket-a', ...) must raise CyclicDependencyError.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_ticket(tracker_dir, "ticket-c", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b", timestamp=1500)
    _write_blocks_link(tracker_dir, "ticket-b", "ticket-c", timestamp=1501)

    with pytest.raises(graph.CyclicDependencyError):
        graph.add_dependency("ticket-c", "ticket-a", str(tracker_dir))


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_cycle_detection_allows_dag(graph: ModuleType, tmp_path: Path) -> None:
    """add_dependency does NOT raise for a valid DAG: A→B, A→C, B→D.

    Setup: ticket-a blocks ticket-b, ticket-a blocks ticket-c, ticket-b blocks ticket-d.
    Action: These are all valid DAG edges — no CyclicDependencyError should be raised.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_ticket(tracker_dir, "ticket-c", status="open")
    _write_ticket(tracker_dir, "ticket-d", status="open")

    # Should not raise
    graph.add_dependency("ticket-a", "ticket-b", str(tracker_dir))
    graph.add_dependency("ticket-a", "ticket-c", str(tracker_dir))
    graph.add_dependency("ticket-b", "ticket-d", str(tracker_dir))


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_visited_set_prevents_infinite_loop(
    graph: ModuleType, tmp_path: Path
) -> None:
    """Diamond graph (A→B, A→C, B→D, C→D) traverses without infinite recursion.

    Setup:
        - ticket-a blocks ticket-b and ticket-c
        - ticket-b blocks ticket-d
        - ticket-c blocks ticket-d
        - All open

    Expected: build_dep_graph('ticket-d', ...) completes without RecursionError or hang.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="open")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_ticket(tracker_dir, "ticket-c", status="open")
    _write_ticket(tracker_dir, "ticket-d", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b", timestamp=1500)
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-c", timestamp=1501)
    _write_blocks_link(tracker_dir, "ticket-b", "ticket-d", timestamp=1502)
    _write_blocks_link(tracker_dir, "ticket-c", "ticket-d", timestamp=1503)

    # Must complete without error (visited set prevents re-traversing ticket-a twice)
    result = graph.build_dep_graph("ticket-d", str(tracker_dir))
    assert isinstance(result, dict), f"Expected dict result, got {type(result)}"


# ---------------------------------------------------------------------------
# Tombstone-awareness
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_archived_ticket_treated_as_closed(
    graph: ModuleType, tmp_path: Path
) -> None:
    """A missing blocker directory (archived/tombstoned) is treated as satisfied.

    Setup:
        - ticket-a: directory MISSING (was archived — its dir does not exist)
        - ticket-b: open, has a LINK event (depends_on ticket-a) in ticket-b's own dir

    Since ticket-a's directory is absent, it is treated as closed → ready_to_work=True.

    Note: The LINK event is stored in ticket-b's directory using relation='depends_on'
    with target_id='ticket-a'. This means ticket-b knows it depends on ticket-a, and
    the relationship is discoverable even when ticket-a's directory is absent.
    This tests tombstone resolution: the implementation must treat a missing blocker
    directory as closed, not as an error.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    # Write ticket-b with a CREATE event and a LINK event (depends_on ticket-a).
    # The LINK lives in ticket-b's directory — ticket-a's directory is never created.
    ticket_b_dir = tracker_dir / "ticket-b"
    ticket_b_dir.mkdir(parents=True)

    create_event = {
        "event_type": "CREATE",
        "uuid": "create-ticket-b",
        "timestamp": 1000,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "ticket_type": "task",
            "title": "Ticket ticket-b",
            "parent_id": None,
        },
    }
    with open(ticket_b_dir / "1000-create-ticket-b-CREATE.json", "w") as f:
        json.dump(create_event, f)

    # ticket-b depends_on ticket-a: LINK event stored in ticket-b's dir.
    # ticket-a's directory does NOT exist (simulates archival / tombstoned blocker).
    link_event = {
        "event_type": "LINK",
        "uuid": "link-ticket-b-depends_on-ticket-a",
        "timestamp": 1500,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "target_id": "ticket-a",
            "relation": "depends_on",
        },
    }
    with open(
        ticket_b_dir / "1500-link-ticket-b-depends_on-ticket-a-LINK.json", "w"
    ) as f:
        json.dump(link_event, f)

    # ticket-a directory intentionally absent (archived/tombstoned)
    assert not (tracker_dir / "ticket-a").exists(), (
        "ticket-a directory must not exist to simulate archival"
    )

    result = graph.build_dep_graph("ticket-b", str(tracker_dir))

    assert result["ready_to_work"] is True, (
        f"Expected ready_to_work=True (blocker ticket-a directory missing = archived), "
        f"got {result!r}"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_tombstone_tombstone_json_respected(
    graph: ModuleType, tmp_path: Path
) -> None:
    """A blocker with .tombstone.json {'status': 'closed'} is treated as closed.

    Setup:
        - ticket-a: directory exists but contains only .tombstone.json
        - ticket-a blocks ticket-b
        - ticket-b: open

    Expected: ready_to_work=True because .tombstone.json signals closed status.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-b", status="open")

    # Create ticket-a directory with only a .tombstone.json
    ticket_a_dir = tracker_dir / "ticket-a"
    ticket_a_dir.mkdir(parents=True)
    tombstone = {"status": "closed", "closed_at": 1700000000}
    with open(ticket_a_dir / ".tombstone.json", "w") as f:
        json.dump(tombstone, f)

    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b", timestamp=1500)

    result = graph.build_dep_graph("ticket-b", str(tracker_dir))

    assert result["ready_to_work"] is True, (
        f"Expected ready_to_work=True (.tombstone.json signals closed), got {result!r}"
    )


# ---------------------------------------------------------------------------
# Performance
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_build_1000_tickets_under_2s(graph: ModuleType, tmp_path: Path) -> None:
    """build_dep_graph for the tail of a 1,000-ticket linear chain completes in <2s.

    Setup:
        - 1,000 ticket directories: ticket-0000 through ticket-0999
        - Linear chain: ticket-0000 blocks ticket-0001, ticket-0001 blocks ticket-0002, ...
        - All tickets are closed except the last (ticket-0999)

    Expected: build_dep_graph('ticket-0999', ...) returns in under 2 seconds.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    n = 1000
    for i in range(n):
        tid = f"ticket-{i:04d}"
        status = "closed" if i < n - 1 else "open"
        _write_ticket(tracker_dir, tid, status=status)

    for i in range(n - 1):
        blocker_id = f"ticket-{i:04d}"
        blocked_id = f"ticket-{i + 1:04d}"
        link_uuid = f"link-{i:04d}"
        _write_blocks_link(
            tracker_dir, blocker_id, blocked_id, link_uuid=link_uuid, timestamp=1500 + i
        )

    start = time.monotonic()
    result = graph.build_dep_graph(f"ticket-{n - 1:04d}", str(tracker_dir))
    elapsed = time.monotonic() - start

    assert elapsed < 2.0, (
        f"build_dep_graph took {elapsed:.3f}s for 1,000-ticket chain (limit: 2.0s)"
    )
    assert isinstance(result, dict), f"Expected dict, got {type(result)}"


@pytest.mark.unit
@pytest.mark.scripts
def test_graph_cache_invalidated_on_new_link(graph: ModuleType, tmp_path: Path) -> None:
    """Graph cache is invalidated when a new LINK event is added to a ticket.

    Setup:
        - ticket-a: closed (blocks ticket-b)
        - ticket-b: open
        - First call: build_dep_graph('ticket-b') → ready_to_work=True (only blocker closed)
        - Add new blocker: ticket-c (open) blocks ticket-b
        - Second call: build_dep_graph('ticket-b') → ready_to_work=False (new blocker open)

    Expected: second call reflects the new dependency — cache was invalidated.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-b", timestamp=1500)

    # First call — ticket-b has one closed blocker → ready_to_work=True
    first_result = graph.build_dep_graph("ticket-b", str(tracker_dir))
    assert first_result["ready_to_work"] is True, (
        f"Pre-condition failed: expected ready_to_work=True before adding new blocker, "
        f"got {first_result!r}"
    )

    # Add a new open blocker
    _write_ticket(tracker_dir, "ticket-c", status="open")
    _write_blocks_link(tracker_dir, "ticket-c", "ticket-b", timestamp=1600)

    # Second call — cache must be invalidated; new blocker (open) detected
    second_result = graph.build_dep_graph("ticket-b", str(tracker_dir))
    assert second_result["ready_to_work"] is False, (
        f"Expected ready_to_work=False after adding open blocker ticket-c, "
        f"got {second_result!r}. Cache may not have been invalidated."
    )
