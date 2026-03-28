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
    parent_id: str | None = None,
    ticket_type: str = "task",
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
            "ticket_type": ticket_type,
            "title": f"Ticket {ticket_id}",
            "parent_id": parent_id,
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


# ---------------------------------------------------------------------------
# Same-second LINK/UNLINK timestamp ordering — _is_active_link must not allow
# UNLINK to replay before LINK when they share the same Unix-second timestamp
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_is_active_link_same_second_unlink_sorts_after_link(
    graph: ModuleType, tmp_path: Path
) -> None:
    """_is_active_link correctly handles LINK+UNLINK events that share the same Unix-second timestamp.

    When a LINK and its cancelling UNLINK share the same timestamp second but have
    different random UUIDs, a pure alphabetic filename sort can place the UNLINK before
    the LINK — making the link appear active when it has been cancelled.

    This test crafts filenames where the UNLINK UUID sorts alphabetically before the LINK UUID
    at the same timestamp, directly exercising the sort-order bug.

    Expected: _is_active_link returns False (link is net-inactive after the UNLINK).
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "src-ticket", status="open")
    _write_ticket(tracker_dir, "tgt-ticket", status="open")

    src_dir = tracker_dir / "src-ticket"

    # The link UUID embedded in the LINK event (and referenced by UNLINK's link_uuid)
    link_uuid = "ffffffff-ffff-4fff-ffff-ffffffffffff"
    # UNLINK UUID starts with '00000000...' → sorts before LINK UUID alphabetically
    unlink_uuid = "00000000-0000-4000-8000-000000000000"
    same_ts = 1000000000

    # Craft filenames so UNLINK sorts before LINK at the same timestamp
    #   UNLINK: "1000000000-00000000-...-UNLINK.json"   ← sorts first alphabetically
    #   LINK:   "1000000000-ffffffff-...-LINK.json"     ← sorts second alphabetically
    link_filename = f"{same_ts}-{link_uuid}-LINK.json"
    unlink_filename = f"{same_ts}-{unlink_uuid}-UNLINK.json"

    # Verify our crafted names actually produce the bad sort order (pre-condition)
    assert unlink_filename < link_filename, (
        "Pre-condition failed: UNLINK filename must sort before LINK filename to exercise the bug. "
        f"Got unlink={unlink_filename!r}, link={link_filename!r}"
    )

    # Write LINK event (link_uuid in 'uuid' field)
    link_event = {
        "event_type": "LINK",
        "uuid": link_uuid,
        "timestamp": same_ts,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "target_id": "tgt-ticket",
            "relation": "blocks",
        },
    }
    with open(src_dir / link_filename, "w") as f:
        json.dump(link_event, f)

    # Write UNLINK event (references link_uuid via data.link_uuid)
    unlink_event = {
        "event_type": "UNLINK",
        "uuid": unlink_uuid,
        "timestamp": same_ts,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "link_uuid": link_uuid,
            "target_id": "tgt-ticket",
            "relation": "blocks",
        },
    }
    with open(src_dir / unlink_filename, "w") as f:
        json.dump(unlink_event, f)

    # _is_active_link must return False: the UNLINK cancels the LINK, net state = inactive
    # With the bug: returns True (UNLINK replayed before LINK → LINK appears active again)
    # With the fix: returns False (LINK always replays before UNLINK at same timestamp)
    result = graph._is_active_link(
        "src-ticket", "tgt-ticket", "blocks", str(tracker_dir)
    )
    assert result is False, (
        "_is_active_link returned True but the link was cancelled by an UNLINK event. "
        "This indicates same-second UNLINK is sorting before LINK — the timestamp "
        "tie-breaker (event_type_order: LINK=0, UNLINK=1) is missing or incorrect."
    )


# ---------------------------------------------------------------------------
# Parent-child (children) tests — bug 8cbf-e13b
# ---------------------------------------------------------------------------


def test_build_dep_graph_includes_children(graph: ModuleType, tmp_path: Path) -> None:
    """build_dep_graph must return a 'children' field listing tickets whose
    parent_id matches the queried ticket.

    Bug 8cbf-e13b: ticket deps returns empty deps for epics with parent-linked
    children because it only traverses dependency links, not parent_id.
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    # Create an epic
    _write_ticket(tracker_dir, "epic-001", ticket_type="epic")
    # Create 3 child stories with parent_id pointing to the epic
    _write_ticket(tracker_dir, "story-a", parent_id="epic-001", ticket_type="story")
    _write_ticket(tracker_dir, "story-b", parent_id="epic-001", ticket_type="story")
    _write_ticket(tracker_dir, "story-c", parent_id="epic-001", ticket_type="story")
    # Create an unrelated ticket (no parent)
    _write_ticket(tracker_dir, "unrelated")

    result = graph.build_dep_graph("epic-001", str(tracker_dir))

    assert "children" in result, (
        "build_dep_graph result is missing 'children' field — "
        "parent-child relationships are not included in the graph output"
    )
    children = sorted(result["children"])
    assert children == ["story-a", "story-b", "story-c"], (
        f"Expected 3 children [story-a, story-b, story-c], got {children}"
    )


def test_build_dep_graph_children_empty_when_no_children(
    graph: ModuleType, tmp_path: Path
) -> None:
    """build_dep_graph must return an empty 'children' list when no tickets
    have parent_id matching the queried ticket."""
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "lonely-ticket")
    _write_ticket(tracker_dir, "other-ticket")

    result = graph.build_dep_graph("lonely-ticket", str(tracker_dir))

    assert "children" in result, "build_dep_graph result missing 'children' field"
    assert result["children"] == [], (
        f"Expected empty children, got {result['children']}"
    )


# ---------------------------------------------------------------------------
# Archive exclusion — RED tests (feature not yet implemented)
# ---------------------------------------------------------------------------


def _write_archive_event(
    tracker_dir: Path, ticket_id: str, timestamp: int = 3000
) -> None:
    """Write an ARCHIVED event to ticket_id's directory.

    This marks the ticket as archived in the event-sourced state.
    The ticket-reducer.py handles ARCHIVED events by setting state['archived'] = True.
    """
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)
    archive_event = {
        "event_type": "ARCHIVED",
        "uuid": f"archive-{ticket_id}",
        "timestamp": timestamp,
        "author": "Test User",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {},
    }
    with open(ticket_dir / f"{timestamp}-archive-{ticket_id}-ARCHIVED.json", "w") as f:
        json.dump(archive_event, f)


@pytest.mark.unit
@pytest.mark.scripts
def test_compute_archive_eligible_regression(graph: ModuleType, tmp_path: Path) -> None:
    """compute_archive_eligible must still see ALL tickets (including archived) — regression guard.

    GREEN: This test passes today and must continue passing after archived exclusion
    is implemented. Placed BEFORE the RED marker so regressions are caught, not tolerated.

    Setup:
        - ticket-already-archived: closed + ARCHIVED event (already archived)
        - ticket-eligible: closed, no blockers, no dependents (should be eligible)
        - ticket-open: open (seed for BFS — not eligible itself)

    Expected:
        compute_archive_eligible returns ticket-eligible (not ticket-already-archived,
        since it's already archived).
    """
    import tempfile

    tracker_dir = Path(tempfile.mkdtemp()) / "tracker"
    tracker_dir.mkdir(parents=True)

    try:
        # ticket-already-archived: closed and already archived
        _write_ticket(tracker_dir, "ticket-already-archived", status="closed")
        _write_archive_event(tracker_dir, "ticket-already-archived")

        # ticket-eligible: closed, not archived, no open deps — should be eligible
        _write_ticket(tracker_dir, "ticket-eligible", status="closed")

        # ticket-open: open, not linked to anything
        _write_ticket(tracker_dir, "ticket-open", status="open")

        eligible = graph.compute_archive_eligible(str(tracker_dir))

        assert "ticket-eligible" in eligible, (
            f"ticket-eligible should be archive-eligible; got {eligible}. "
            "compute_archive_eligible must still scan all tickets including archived ones."
        )

        assert "ticket-already-archived" not in eligible, (
            f"ticket-already-archived is already archived, must not be re-eligible; "
            f"got {eligible}"
        )

        assert "ticket-open" not in eligible, (
            f"ticket-open is not closed, must not be eligible; got {eligible}"
        )
    finally:
        import shutil

        shutil.rmtree(str(tracker_dir.parent), ignore_errors=True)


@pytest.mark.unit
@pytest.mark.scripts
def test_transitive_traversal_includes_archived_midchain(
    graph: ModuleType, tmp_path: Path
) -> None:
    """Transitive blocker traversal must NOT skip archived tickets mid-chain — regression guard.

    GREEN: This test passes today and must continue passing after archived exclusion
    is implemented. Placed BEFORE the RED marker so regressions are caught, not tolerated.

    Setup:
        - ticket-a: open, blocks ticket-b
        - ticket-b: open, ARCHIVED, blocks ticket-c
        - ticket-c: open (the ticket we query)

    Expected: check_would_create_cycle('ticket-c', 'ticket-a', 'blocks', ...) == True
    """
    import tempfile

    tracker_dir = Path(tempfile.mkdtemp()) / "tracker"
    tracker_dir.mkdir(parents=True)

    try:
        _write_ticket(tracker_dir, "ticket-a", status="open")
        _write_ticket(tracker_dir, "ticket-b", status="open")
        _write_ticket(tracker_dir, "ticket-c", status="open")
        _write_blocks_link(tracker_dir, "ticket-a", "ticket-b", timestamp=1500)
        _write_blocks_link(tracker_dir, "ticket-b", "ticket-c", timestamp=1501)
        _write_archive_event(tracker_dir, "ticket-b")

        would_cycle = graph.check_would_create_cycle(
            "ticket-c", "ticket-a", "blocks", str(tracker_dir)
        )

        assert would_cycle is True, (
            "check_would_create_cycle must detect cycle through archived mid-chain ticket-b. "
            "Archived exclusion must NOT prune nodes during transitive traversal. "
            f"Got would_cycle={would_cycle!r} (expected True)."
        )
    finally:
        import shutil

        shutil.rmtree(str(tracker_dir.parent), ignore_errors=True)


# ── RED MARKER BOUNDARY ──────────────────────────────────────────────────────
# Tests below this line are expected to FAIL (RED) until archived exclusion is
# implemented in ticket-graph.py. The .test-index RED marker points to the first
# test below (test_build_dep_graph_excludes_archived_children).
# Tests ABOVE this line are GREEN regression guards that must always pass.


@pytest.mark.unit
@pytest.mark.scripts
def test_build_dep_graph_excludes_archived_children(
    graph: ModuleType, tmp_path: Path
) -> None:
    """build_dep_graph must exclude archived tickets from the children list by default.

    Setup:
        - epic-001: open epic
        - story-active: open, parent_id=epic-001 (not archived)
        - story-archived: open, parent_id=epic-001, then ARCHIVED event written

    Expected (default exclude_archived=True):
        result['children'] contains only story-active, not story-archived.

    This test is RED — archived exclusion is not yet implemented.
    To make it GREEN: add exclude_archived parameter to build_dep_graph
    (default True) and filter children by archived status.
    """
    import tempfile

    tracker_dir = Path(tempfile.mkdtemp()) / "tracker"
    tracker_dir.mkdir(parents=True)

    try:
        _write_ticket(tracker_dir, "epic-001", ticket_type="epic")
        _write_ticket(
            tracker_dir, "story-active", parent_id="epic-001", ticket_type="story"
        )
        _write_ticket(
            tracker_dir, "story-archived", parent_id="epic-001", ticket_type="story"
        )
        _write_archive_event(tracker_dir, "story-archived")

        result = graph.build_dep_graph("epic-001", str(tracker_dir))

        assert "children" in result, "build_dep_graph result missing 'children' field"
        assert "story-active" in result["children"], (
            f"story-active should be in children; got {result['children']}"
        )
        assert "story-archived" not in result["children"], (
            f"story-archived (archived) should NOT be in children by default; "
            f"got {result['children']}. "
            "Archived tickets must be excluded from children by default."
        )
    finally:
        import shutil

        shutil.rmtree(str(tracker_dir.parent), ignore_errors=True)


@pytest.mark.unit
@pytest.mark.scripts
def test_build_dep_graph_excludes_archived_blockers(
    graph: ModuleType, tmp_path: Path
) -> None:
    """build_dep_graph must exclude archived tickets from the blockers list by default.

    Setup:
        - ticket-active-blocker: open, blocks ticket-target
        - ticket-archived-blocker: open, blocks ticket-target, then ARCHIVED event written
        - ticket-target: open

    Expected (default exclude_archived=True):
        result['blockers'] contains only ticket-active-blocker,
        not ticket-archived-blocker.

    This test is RED — archived exclusion in blockers is not yet implemented.
    """
    import tempfile

    tracker_dir = Path(tempfile.mkdtemp()) / "tracker"
    tracker_dir.mkdir(parents=True)

    try:
        _write_ticket(tracker_dir, "ticket-active-blocker", status="open")
        _write_ticket(tracker_dir, "ticket-archived-blocker", status="open")
        _write_ticket(tracker_dir, "ticket-target", status="open")
        _write_blocks_link(
            tracker_dir, "ticket-active-blocker", "ticket-target", timestamp=1500
        )
        _write_blocks_link(
            tracker_dir, "ticket-archived-blocker", "ticket-target", timestamp=1501
        )
        _write_archive_event(tracker_dir, "ticket-archived-blocker")

        result = graph.build_dep_graph("ticket-target", str(tracker_dir))

        assert "blockers" in result, "build_dep_graph result missing 'blockers' field"
        assert "ticket-active-blocker" in result["blockers"], (
            f"ticket-active-blocker should be in blockers; got {result['blockers']}"
        )
        assert "ticket-archived-blocker" not in result["blockers"], (
            f"ticket-archived-blocker (archived) should NOT be in blockers by default; "
            f"got {result['blockers']}. "
            "Archived tickets must be excluded from blockers by default."
        )
    finally:
        import shutil

        shutil.rmtree(str(tracker_dir.parent), ignore_errors=True)


@pytest.mark.unit
@pytest.mark.scripts
def test_deps_cli_include_archived(tmp_path: Path) -> None:
    """ticket-graph.py CLI with --include-archived returns full graph including archived.

    Setup:
        - ticket-parent: epic
        - ticket-child-active: story, parent_id=ticket-parent (not archived)
        - ticket-child-archived: story, parent_id=ticket-parent, ARCHIVED

    Without --include-archived: children = [ticket-child-active] (archived excluded by default)
    With --include-archived: children = [ticket-child-active, ticket-child-archived]

    This test is RED — default archived exclusion is not yet implemented, so the
    without-flag case incorrectly includes the archived child.
    """
    import subprocess
    import tempfile

    tracker_dir = Path(tempfile.mkdtemp()) / "tracker"
    tracker_dir.mkdir(parents=True)

    try:
        _write_ticket(tracker_dir, "ticket-parent", ticket_type="epic")
        _write_ticket(
            tracker_dir,
            "ticket-child-active",
            parent_id="ticket-parent",
            ticket_type="story",
        )
        _write_ticket(
            tracker_dir,
            "ticket-child-archived",
            parent_id="ticket-parent",
            ticket_type="story",
        )
        _write_archive_event(tracker_dir, "ticket-child-archived")

        # First: verify default behavior excludes archived (RED — not yet implemented)
        result_default = subprocess.run(
            [
                "python3",
                str(SCRIPT_PATH),
                "ticket-parent",
                f"--tickets-dir={tracker_dir}",
            ],
            capture_output=True,
            text=True,
        )

        assert result_default.returncode == 0, (
            f"CLI (no flag) exited with {result_default.returncode}; "
            f"stderr={result_default.stderr!r}"
        )
        output_default = json.loads(result_default.stdout)
        children_default = output_default.get("children", [])
        assert "ticket-child-archived" not in children_default, (
            f"Without --include-archived, archived child must be excluded by default; "
            f"children={children_default}. "
            "Default archived exclusion is not yet implemented."
        )

        # Second: verify --include-archived includes the archived child
        result_with_flag = subprocess.run(
            [
                "python3",
                str(SCRIPT_PATH),
                "ticket-parent",
                f"--tickets-dir={tracker_dir}",
                "--include-archived",
            ],
            capture_output=True,
            text=True,
        )

        assert result_with_flag.returncode == 0, (
            f"CLI (--include-archived) exited with {result_with_flag.returncode}; "
            f"stderr={result_with_flag.stderr!r}. "
            "--include-archived flag must be recognized and return exit 0."
        )

        output_with_flag = json.loads(result_with_flag.stdout)
        children_with_flag = output_with_flag.get("children", [])
        assert "ticket-child-archived" in children_with_flag, (
            f"With --include-archived, archived child must appear in result; "
            f"children={children_with_flag}. "
            "--include-archived flag is not yet implemented."
        )
        assert "ticket-child-active" in children_with_flag, (
            f"With --include-archived, active child must still appear; "
            f"children={children_with_flag}"
        )
    finally:
        import shutil

        shutil.rmtree(str(tracker_dir.parent), ignore_errors=True)


@pytest.mark.unit
@pytest.mark.scripts
def test_deps_archived_direct_target_error(tmp_path: Path) -> None:
    """CLI: querying deps for an archived ticket directly exits 1 with a helpful message.

    When a user runs `ticket-graph.py <archived-ticket-id> --tickets-dir=...`,
    the ticket exists on disk but is archived. The CLI must:
      - Exit with code 1
      - Print a message to stderr suggesting --include-archived

    This guards against silently returning an empty/stale graph for an archived ticket
    when the user likely needs to use --include-archived.

    This test is RED — the archived-ticket-direct-query guard is not yet implemented.
    """
    import subprocess
    import tempfile

    tracker_dir = Path(tempfile.mkdtemp()) / "tracker"
    tracker_dir.mkdir(parents=True)

    try:
        # Create an archived ticket
        _write_ticket(tracker_dir, "ticket-archived", status="closed")
        _write_archive_event(tracker_dir, "ticket-archived")

        result = subprocess.run(
            [
                "python3",
                str(SCRIPT_PATH),
                "ticket-archived",
                f"--tickets-dir={tracker_dir}",
            ],
            capture_output=True,
            text=True,
        )

        assert result.returncode == 1, (
            f"CLI must exit 1 when querying an archived ticket directly; "
            f"got returncode={result.returncode}. "
            "The archived-ticket guard is not yet implemented."
        )
        assert "--include-archived" in result.stderr, (
            f"CLI stderr must suggest --include-archived when querying archived ticket; "
            f"got stderr={result.stderr!r}. "
            "The error message must guide users to the correct flag."
        )
    finally:
        import shutil

        shutil.rmtree(str(tracker_dir.parent), ignore_errors=True)


# ── RED MARKER BOUNDARY ──────────────────────────────────────────────────────
# Tests below this line are expected to FAIL (RED) until ticket-graph.py is
# refactored to use a single reduce_all_tickets call for deps operations.
# The .test-index RED marker points to the first test below:
# test_build_dep_graph_single_batch_scan
# Tests ABOVE this line are GREEN and must always pass.


@pytest.mark.unit
@pytest.mark.scripts
def test_build_dep_graph_single_batch_scan(graph: ModuleType, tmp_path: Path) -> None:
    """build_dep_graph must use a single reduce_all_tickets call instead of per-ticket scans.

    Setup:
        - A tracker with 5 tickets: ticket-a (closed, blocks ticket-e), ticket-b,
          ticket-c, ticket-d (all open), ticket-e (open, target ticket).

    Expected: reduce_all_tickets is called exactly once during build_dep_graph.

    Currently RED: build_dep_graph calls _reduce_ticket per-ticket via
    _compute_dep_graph and _find_direct_blockers. It does not call reduce_all_tickets.
    """
    from unittest.mock import patch

    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a", status="closed")
    _write_ticket(tracker_dir, "ticket-b", status="open")
    _write_ticket(tracker_dir, "ticket-c", status="open")
    _write_ticket(tracker_dir, "ticket-d", status="open")
    _write_ticket(tracker_dir, "ticket-e", status="open")
    _write_blocks_link(tracker_dir, "ticket-a", "ticket-e")

    # Capture the real reduce_all_tickets so the patch can delegate to it
    real_reduce_all = graph._reducer.reduce_all_tickets

    call_count = []

    def counting_reduce_all(*args, **kwargs):  # type: ignore[no-untyped-def]
        call_count.append(1)
        return real_reduce_all(*args, **kwargs)

    with patch.object(
        graph._reducer, "reduce_all_tickets", side_effect=counting_reduce_all
    ):
        graph.build_dep_graph("ticket-e", str(tracker_dir))

    assert len(call_count) == 1, (
        f"Expected reduce_all_tickets to be called exactly once during build_dep_graph, "
        f"but it was called {len(call_count)} time(s). "
        "build_dep_graph must pre-load all ticket states via a single reduce_all_tickets "
        "call instead of calling _reduce_ticket per-ticket in _find_direct_blockers and "
        "_compute_dep_graph."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_find_direct_blockers_no_per_ticket_scan(
    graph: ModuleType, tmp_path: Path
) -> None:
    """_find_direct_blockers must not call _reduce_ticket directly — use pre-loaded state.

    Setup:
        - ticket-blocker: open, blocks ticket-target
        - ticket-target: open

    Pre-loaded state dict is passed in. _reduce_ticket must NOT be called.

    Currently RED: _find_direct_blockers calls _reduce_ticket directly for each
    ticket dir it scans. After refactor, it must accept a pre-loaded all_states
    dict and use that instead.
    """
    from unittest.mock import patch

    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-blocker", status="open")
    _write_ticket(tracker_dir, "ticket-target", status="open")
    _write_blocks_link(tracker_dir, "ticket-blocker", "ticket-target")

    reduce_ticket_calls = []

    def spy_reduce_ticket(*args, **kwargs):  # type: ignore[no-untyped-def]
        reduce_ticket_calls.append(args)
        return graph._reduce_ticket(*args, **kwargs)

    with patch.object(graph, "_reduce_ticket", side_effect=spy_reduce_ticket):
        # After refactor, _find_direct_blockers should accept all_states and not call _reduce_ticket
        graph._find_direct_blockers("ticket-target", str(tracker_dir))

    assert len(reduce_ticket_calls) == 0, (
        f"Expected _reduce_ticket to be called 0 times in _find_direct_blockers "
        f"(should use pre-loaded state), but it was called {len(reduce_ticket_calls)} time(s). "
        "_find_direct_blockers must be refactored to accept a pre-loaded all_states dict "
        "and look up ticket states from it instead of calling _reduce_ticket per ticket."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_compute_dep_graph_children_use_preloaded_state(
    graph: ModuleType, tmp_path: Path
) -> None:
    """_compute_dep_graph must not call _reduce_ticket for children discovery.

    Setup:
        - parent-epic: epic with 3 child stories
        - story-a, story-b, story-c: open stories with parent_id=parent-epic

    Expected: _reduce_ticket is NOT called during _compute_dep_graph. All state
    lookups should use a pre-loaded all_states dict passed in from build_dep_graph.

    Currently RED: _compute_dep_graph calls _reduce_ticket for each directory entry
    to discover children. After refactor, it must use pre-loaded state.
    """
    from unittest.mock import patch

    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "parent-epic", ticket_type="epic")
    _write_ticket(tracker_dir, "story-a", parent_id="parent-epic", ticket_type="story")
    _write_ticket(tracker_dir, "story-b", parent_id="parent-epic", ticket_type="story")
    _write_ticket(tracker_dir, "story-c", parent_id="parent-epic", ticket_type="story")

    reduce_ticket_calls = []

    def spy_reduce_ticket(*args, **kwargs):  # type: ignore[no-untyped-def]
        reduce_ticket_calls.append(args)
        return graph._reduce_ticket(*args, **kwargs)

    with patch.object(graph, "_reduce_ticket", side_effect=spy_reduce_ticket):
        graph._compute_dep_graph("parent-epic", str(tracker_dir))

    assert len(reduce_ticket_calls) == 0, (
        f"Expected _reduce_ticket to be called 0 times in _compute_dep_graph "
        f"(should use pre-loaded state for children discovery), "
        f"but it was called {len(reduce_ticket_calls)} time(s). "
        "_compute_dep_graph must be refactored to receive a pre-loaded all_states dict "
        "and use it for both children discovery and blocker resolution instead of "
        "calling _reduce_ticket per directory entry."
    )
