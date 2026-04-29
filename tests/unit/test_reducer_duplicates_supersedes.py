"""Tests verifying duplicates and supersedes relation round-trip through reducer and ticket deps output.

These tests verify:
  1. The reducer preserves 'duplicates' and 'supersedes' relation strings in state.deps
  2. ticket-graph's build_dep_graph returns them in the deps array
  3. duplicates/supersedes do NOT appear in blockers or affect ready_to_work
  4. LLM format (to_llm) surfaces deps with r: "duplicates" / r: "supersedes"
  5. UNLINK events cancel duplicates/supersedes links correctly
  6. ready_to_work is governed solely by blocking relations (blocks / depends_on)

Design: Uses direct Python API (ticket_reducer + ticket_graph) rather than CLI subprocesses.
All fixtures are written inline using the same helper pattern as test_ticket_graph.py.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Path setup — conftest.py adds plugins/dso/scripts to sys.path, but we
# also need ticket_graph which lives under the same scripts directory.
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from ticket_reducer import reduce_all_tickets  # noqa: E402  (after sys.path setup)
from ticket_reducer.llm_format import to_llm  # noqa: E402

# Load ticket_graph module (filename has no hyphens so import works directly)
_TICKET_GRAPH_SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-graph.py"


def _load_ticket_graph() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "ticket_graph_main", _TICKET_GRAPH_SCRIPT
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def graph() -> ModuleType:
    """Return the ticket-graph module's build_dep_graph function."""
    if not _TICKET_GRAPH_SCRIPT.exists():
        pytest.fail(f"ticket-graph.py not found at {_TICKET_GRAPH_SCRIPT}")
    return _load_ticket_graph()


# ---------------------------------------------------------------------------
# Fixture helpers — write minimal event-sourced ticket directories
# ---------------------------------------------------------------------------

_TS_BASE = 1_000_000  # base timestamp to keep filenames predictable


def _write_ticket(
    tracker_dir: Path,
    ticket_id: str,
    status: str = "open",
    ticket_type: str = "task",
    parent_id: str | None = None,
) -> None:
    """Write a minimal ticket directory with a CREATE event and optional STATUS event."""
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    create_event = {
        "event_type": "CREATE",
        "uuid": f"create-{ticket_id}",
        "timestamp": _TS_BASE,
        "author": "Test",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "ticket_type": ticket_type,
            "title": f"Ticket {ticket_id}",
            "parent_id": parent_id,
        },
    }
    with open(ticket_dir / f"{_TS_BASE}-create-{ticket_id}-CREATE.json", "w") as f:
        json.dump(create_event, f)

    if status != "open":
        status_event = {
            "event_type": "STATUS",
            "uuid": f"status-{ticket_id}",
            "timestamp": _TS_BASE + 1000,
            "author": "Test",
            "env_id": "00000000-0000-4000-8000-000000000001",
            "data": {
                "status": status,
                "current_status": "open",
            },
        }
        with open(
            ticket_dir / f"{_TS_BASE + 1000}-status-{ticket_id}-STATUS.json", "w"
        ) as f:
            json.dump(status_event, f)


def _write_link(
    tracker_dir: Path,
    source_id: str,
    target_id: str,
    relation: str,
    link_uuid: str | None = None,
    timestamp: int = _TS_BASE + 500,
) -> str:
    """Write a LINK event in source_id's directory. Returns the link_uuid."""
    if link_uuid is None:
        link_uuid = f"link-{source_id}-{relation}-{target_id}"
    source_dir = tracker_dir / source_id
    source_dir.mkdir(parents=True, exist_ok=True)
    link_event = {
        "event_type": "LINK",
        "uuid": link_uuid,
        "timestamp": timestamp,
        "author": "Test",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "target_id": target_id,
            "relation": relation,
        },
    }
    filename = f"{timestamp}-{link_uuid}-LINK.json"
    with open(source_dir / filename, "w") as f:
        json.dump(link_event, f)
    return link_uuid


def _write_unlink(
    tracker_dir: Path,
    source_id: str,
    link_uuid: str,
    target_id: str,
    relation: str,
    timestamp: int = _TS_BASE + 600,
) -> None:
    """Write an UNLINK event in source_id's directory, cancelling a prior LINK."""
    unlink_uuid = f"unlink-{link_uuid}"
    source_dir = tracker_dir / source_id
    source_dir.mkdir(parents=True, exist_ok=True)
    unlink_event = {
        "event_type": "UNLINK",
        "uuid": unlink_uuid,
        "timestamp": timestamp,
        "author": "Test",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "link_uuid": link_uuid,
            "target_id": target_id,
            "relation": relation,
        },
    }
    filename = f"{timestamp}-{unlink_uuid}-UNLINK.json"
    with open(source_dir / filename, "w") as f:
        json.dump(unlink_event, f)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_deps_output_includes_duplicates_relation(
    graph: ModuleType, tmp_path: Path
) -> None:
    """ticket-graph deps output includes an entry with relation='duplicates'.

    Setup:
        - ticket-a: open, has LINK(duplicates) → ticket-b
        - ticket-b: open

    Expected:
        - result['deps'] contains an entry with relation='duplicates' and target_id='ticket-b'
        - result['blockers'] does NOT contain 'ticket-b'
        - result['ready_to_work'] == True (duplicates is non-blocking)
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")
    _write_link(tracker_dir, "ticket-a", "ticket-b", relation="duplicates")

    result = graph.build_dep_graph("ticket-a", str(tracker_dir))

    dep_relations = {d.get("relation") for d in result["deps"]}
    assert "duplicates" in dep_relations, (
        f"Expected 'duplicates' relation in deps; got deps={result['deps']!r}"
    )

    dep_targets = {
        d.get("target_id") for d in result["deps"] if d.get("relation") == "duplicates"
    }
    assert "ticket-b" in dep_targets, (
        f"Expected target_id='ticket-b' in duplicates deps; got deps={result['deps']!r}"
    )

    assert "ticket-b" not in result["blockers"], (
        f"'ticket-b' must NOT be in blockers for a duplicates relation; "
        f"got blockers={result['blockers']!r}"
    )

    assert result["ready_to_work"] is True, (
        f"Expected ready_to_work=True (duplicates is non-blocking); got {result!r}"
    )


@pytest.mark.unit
def test_deps_output_includes_supersedes_relation(
    graph: ModuleType, tmp_path: Path
) -> None:
    """ticket-graph deps output includes an entry with relation='supersedes'.

    Setup:
        - ticket-a: open, has LINK(supersedes) → ticket-b
        - ticket-b: open

    Expected:
        - result['deps'] contains an entry with relation='supersedes' and target_id='ticket-b'
        - result['blockers'] does NOT contain 'ticket-b'
        - result['ready_to_work'] == True (supersedes is non-blocking)
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")
    _write_link(tracker_dir, "ticket-a", "ticket-b", relation="supersedes")

    result = graph.build_dep_graph("ticket-a", str(tracker_dir))

    dep_relations = {d.get("relation") for d in result["deps"]}
    assert "supersedes" in dep_relations, (
        f"Expected 'supersedes' relation in deps; got deps={result['deps']!r}"
    )

    dep_targets = {
        d.get("target_id") for d in result["deps"] if d.get("relation") == "supersedes"
    }
    assert "ticket-b" in dep_targets, (
        f"Expected target_id='ticket-b' in supersedes deps; got deps={result['deps']!r}"
    )

    assert "ticket-b" not in result["blockers"], (
        f"'ticket-b' must NOT be in blockers for a supersedes relation; "
        f"got blockers={result['blockers']!r}"
    )

    assert result["ready_to_work"] is True, (
        f"Expected ready_to_work=True (supersedes is non-blocking); got {result!r}"
    )


@pytest.mark.unit
def test_show_llm_format_surfaces_duplicates_in_dp_array(tmp_path: Path) -> None:
    """to_llm() surfaces a duplicates link in the 'dp' array with r='duplicates' and tid='ticket-b'.

    Setup:
        - ticket-a: open, LINK(duplicates) → ticket-b (written directly into ticket-a's dir)
        - ticket-b: open

    This test uses reduce_all_tickets directly then to_llm() to verify the LLM format.

    Expected:
        - LLM state has 'dp' key
        - dp contains an entry {tid: 'ticket-b', r: 'duplicates'}
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")
    _write_link(tracker_dir, "ticket-a", "ticket-b", relation="duplicates")

    all_states = reduce_all_tickets(str(tracker_dir))
    state_a = next((s for s in all_states if s.get("ticket_id") == "ticket-a"), None)
    assert state_a is not None, "reduce_all_tickets did not return state for ticket-a"

    llm_state = to_llm(state_a)

    assert "dp" in llm_state, (
        f"Expected 'dp' key in LLM state for ticket-a; got keys: {list(llm_state.keys())!r}"
    )

    dp = llm_state["dp"]
    matched = [
        entry
        for entry in dp
        if entry.get("r") == "duplicates" and entry.get("tid") == "ticket-b"
    ]
    assert matched, (
        f"Expected dp entry with r='duplicates' and tid='ticket-b'; got dp={dp!r}"
    )


@pytest.mark.unit
def test_reducer_unlink_cancels_duplicates_link(
    graph: ModuleType, tmp_path: Path
) -> None:
    """An UNLINK event cancels a prior duplicates LINK; the relation no longer appears in deps.

    Setup:
        - ticket-a: open, LINK(duplicates, uuid=link-dup) → ticket-b
        - UNLINK(link_uuid=link-dup) written after the LINK

    Expected:
        - result['deps'] does NOT contain any entry with relation='duplicates' targeting ticket-b
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")

    link_uuid = _write_link(
        tracker_dir,
        "ticket-a",
        "ticket-b",
        relation="duplicates",
        link_uuid="link-dup-uuid-001",
        timestamp=_TS_BASE + 500,
    )

    _write_unlink(
        tracker_dir,
        "ticket-a",
        link_uuid=link_uuid,
        target_id="ticket-b",
        relation="duplicates",
        timestamp=_TS_BASE + 600,
    )

    result = graph.build_dep_graph("ticket-a", str(tracker_dir))

    cancelled_deps = [
        d
        for d in result["deps"]
        if d.get("relation") == "duplicates" and d.get("target_id") == "ticket-b"
    ]
    assert not cancelled_deps, (
        f"Expected no 'duplicates' deps after UNLINK cancellation; "
        f"got deps={result['deps']!r}"
    )


@pytest.mark.unit
def test_show_llm_format_surfaces_supersedes_in_dp_array(tmp_path: Path) -> None:
    """to_llm() surfaces a supersedes link in the 'dp' array with r='supersedes' and tid='ticket-b'.

    Setup:
        - ticket-a: open, LINK(supersedes) → ticket-b (written directly into ticket-a's dir)
        - ticket-b: open

    Expected:
        - LLM state has 'dp' key
        - dp contains an entry {tid: 'ticket-b', r: 'supersedes'}
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")
    _write_link(tracker_dir, "ticket-a", "ticket-b", relation="supersedes")

    all_states = reduce_all_tickets(str(tracker_dir))
    state_a = next((s for s in all_states if s.get("ticket_id") == "ticket-a"), None)
    assert state_a is not None, "reduce_all_tickets did not return state for ticket-a"

    llm_state = to_llm(state_a)

    assert "dp" in llm_state, (
        f"Expected 'dp' key in LLM state for ticket-a; got keys: {list(llm_state.keys())!r}"
    )

    dp = llm_state["dp"]
    matched = [
        entry
        for entry in dp
        if entry.get("r") == "supersedes" and entry.get("tid") == "ticket-b"
    ]
    assert matched, (
        f"Expected dp entry with r='supersedes' and tid='ticket-b'; got dp={dp!r}"
    )


@pytest.mark.unit
def test_reducer_unlink_cancels_supersedes_link(
    graph: ModuleType, tmp_path: Path
) -> None:
    """An UNLINK event cancels a prior supersedes LINK; the relation no longer appears in deps.

    Setup:
        - ticket-a: open, LINK(supersedes, uuid=link-sup) → ticket-b
        - UNLINK(link_uuid=link-sup) written after the LINK

    Expected:
        - result['deps'] does NOT contain any entry with relation='supersedes' targeting ticket-b
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")

    link_uuid = _write_link(
        tracker_dir,
        "ticket-a",
        "ticket-b",
        relation="supersedes",
        link_uuid="link-sup-uuid-001",
        timestamp=_TS_BASE + 500,
    )

    _write_unlink(
        tracker_dir,
        "ticket-a",
        link_uuid=link_uuid,
        target_id="ticket-b",
        relation="supersedes",
        timestamp=_TS_BASE + 600,
    )

    result = graph.build_dep_graph("ticket-a", str(tracker_dir))

    cancelled_deps = [
        d
        for d in result["deps"]
        if d.get("relation") == "supersedes" and d.get("target_id") == "ticket-b"
    ]
    assert not cancelled_deps, (
        f"Expected no 'supersedes' deps after UNLINK cancellation; "
        f"got deps={result['deps']!r}"
    )


@pytest.mark.unit
def test_ready_to_work_unaffected_by_duplicates(
    graph: ModuleType, tmp_path: Path
) -> None:
    """ready_to_work is governed by blocking relations only; duplicates does not affect it.

    Setup:
        - ticket-a: open
        - ticket-b: open (blocks ticket-a via depends_on from ticket-a's perspective)
        - ticket-c: open (ticket-a duplicates ticket-c — non-blocking)

    Phase 1: ticket-b is open → ready_to_work=False
    Phase 2: close ticket-b → ready_to_work=True regardless of duplicates link to ticket-c
    """
    tracker_dir = tmp_path / "tracker"
    tracker_dir.mkdir()

    _write_ticket(tracker_dir, "ticket-a")
    _write_ticket(tracker_dir, "ticket-b")  # will be the blocker
    _write_ticket(tracker_dir, "ticket-c")  # duplicate target, never closed

    # ticket-a depends_on ticket-b (blocking)
    _write_link(
        tracker_dir,
        "ticket-a",
        "ticket-b",
        relation="depends_on",
        timestamp=_TS_BASE + 500,
    )
    # ticket-a duplicates ticket-c (non-blocking)
    _write_link(
        tracker_dir,
        "ticket-a",
        "ticket-c",
        relation="duplicates",
        timestamp=_TS_BASE + 501,
    )

    # Phase 1: ticket-b open → ready_to_work must be False
    result_blocked = graph.build_dep_graph("ticket-a", str(tracker_dir))
    assert result_blocked["ready_to_work"] is False, (
        f"Expected ready_to_work=False while ticket-b (blocker) is open; "
        f"got {result_blocked!r}"
    )
    assert "ticket-b" in result_blocked["blockers"], (
        f"Expected ticket-b in blockers; got blockers={result_blocked['blockers']!r}"
    )
    assert "ticket-c" not in result_blocked["blockers"], (
        f"ticket-c (duplicates) must NOT be in blockers; "
        f"got blockers={result_blocked['blockers']!r}"
    )

    # Phase 2: close ticket-b by writing a STATUS event
    status_event = {
        "event_type": "STATUS",
        "uuid": "status-close-ticket-b",
        "timestamp": _TS_BASE + 2000,
        "author": "Test",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "data": {
            "status": "closed",
            "current_status": "open",
        },
    }
    ticket_b_dir = tracker_dir / "ticket-b"
    with open(
        ticket_b_dir / f"{_TS_BASE + 2000}-status-close-ticket-b-STATUS.json", "w"
    ) as f:
        json.dump(status_event, f)

    result_unblocked = graph.build_dep_graph("ticket-a", str(tracker_dir))
    assert result_unblocked["ready_to_work"] is True, (
        f"Expected ready_to_work=True after ticket-b (blocker) is closed; "
        f"got {result_unblocked!r}. "
        "The duplicates link to ticket-c must not prevent ready_to_work from becoming True."
    )
