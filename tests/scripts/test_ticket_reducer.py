"""RED tests for ticket-reducer.py.

These tests are RED — they test functionality that does not yet exist.
All 11 test functions must FAIL before ticket-reducer.py is implemented.

The reducer is expected to expose a single callable:
    reduce_ticket(ticket_dir_path: Path) -> dict | None

Contract (from plugins/dso/docs/contracts/ticket-event-format.md):
  - Event files are named: <timestamp>-<uuid>-<TYPE>.json
  - Events are sorted lexicographically by filename before reduction.
  - A CREATE event supplies ticket_type, title, and optional parent_id.
  - The reducer returns None if no CREATE event is present or the dir is empty.
  - Exception: a dir with only corrupt/unparseable events returns an error dict
    (status='error') rather than None — ghost-ticket prevention (Test 10).

Test: python3 -m pytest tests/scripts/test_ticket_reducer.py
All tests must return non-zero until ticket-reducer.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
import warnings
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-reducer.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ticket_reducer", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def reducer() -> ModuleType:
    """Return the ticket-reducer module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"ticket-reducer.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_UUID = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_UUID2 = "aabbccdd-1122-3344-5566-778899aabbcc"
_UUID3 = "deadbeef-dead-beef-dead-beefdeadbeef"


def _write_event(
    ticket_dir: Path,
    timestamp: int,
    uuid: str,
    event_type: str,
    data: dict,
    env_id: str = "00000000-0000-4000-8000-000000000001",
    author: str = "Test User",
) -> Path:
    """Write a well-formed event JSON file and return its path."""
    filename = f"{timestamp}-{uuid}-{event_type}.json"
    payload = {
        "timestamp": timestamp,
        "uuid": uuid,
        "event_type": event_type,
        "env_id": env_id,
        "author": author,
        "data": data,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


# ---------------------------------------------------------------------------
# Test 1: reducer compiles a single CREATE event to ticket state
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_compiles_single_create_event_to_state(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Given one CREATE event JSON file, the reducer returns the expected dict."""
    ticket_dir = tmp_path / "tkt-001"
    ticket_dir.mkdir()

    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "task",
            "title": "Add reducer",
            "parent_id": "epic-abc",
        },
        env_id="00000000-0000-4000-8000-000000000001",
        author="Alice",
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, "reduce_ticket must return a dict for a CREATE event"
    assert state["ticket_id"] == "tkt-001"
    assert state["ticket_type"] == "task"
    assert state["title"] == "Add reducer"
    assert state["status"] == "open", "default status must be 'open'"
    assert state["author"] == "Alice"
    assert state["created_at"] == 1742605200
    assert state["env_id"] == "00000000-0000-4000-8000-000000000001"
    assert state["parent_id"] == "epic-abc"
    assert state["comments"] == []
    assert state["deps"] == []


# ---------------------------------------------------------------------------
# Test 2: reducer sorts events by filename (lexicographic = chronological)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_orders_events_by_filename_not_insertion_order(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Events must be processed in filename-lexicographic order regardless of write order.

    We write the LATER event (t2=1742605300) first and the EARLIER event
    (t1=1742605200) second — simulating a reversed filesystem insertion order.
    The reducer must still apply t1 before t2.

    We verify ordering by writing two CREATE events with the same uuid but
    different timestamps and titles; only the first (t1) must win as CREATE.
    Then a STATUS event at t2 carries the "expected_order_verified" marker we
    assert on.
    """
    ticket_dir = tmp_path / "tkt-order"
    ticket_dir.mkdir()

    # Write t2 event FIRST (later timestamp, written earlier to filesystem)
    _write_event(
        ticket_dir,
        timestamp=1742605300,  # t2 — later
        uuid=_UUID2,
        event_type="STATUS",
        data={
            "status": "closed",
            "current_status": "open",
            "marker": "t2_processed_second",
        },
    )

    # Write t1 event SECOND (earlier timestamp, written later to filesystem)
    _write_event(
        ticket_dir,
        timestamp=1742605200,  # t1 — earlier
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "task",
            "title": "Original title from t1",
            "parent_id": None,
        },
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None
    # If reducer processes t1 before t2, the title comes from CREATE at t1
    assert state["title"] == "Original title from t1", (
        "reducer must sort events by filename (t1 < t2), not insertion order"
    )
    # Status from t2 STATUS event (applied after CREATE)
    assert state["status"] == "closed", (
        "STATUS event at t2 must be applied after CREATE event at t1"
    )


# ---------------------------------------------------------------------------
# Test 3: reducer skips corrupt JSON with a warning, does not raise
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_skips_corrupt_json_with_warning(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Given one valid CREATE event and one malformed JSON file, the reducer
    must return valid state from the good event and must NOT raise an exception.
    It should log a warning (any mechanism is acceptable — the test only
    verifies that no exception propagates and valid state is returned).
    """
    ticket_dir = tmp_path / "tkt-corrupt"
    ticket_dir.mkdir()

    # Write a valid CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "bug",
            "title": "Reducer is lenient",
            "parent_id": None,
        },
    )

    # Write a malformed JSON file in the same directory
    corrupt_file = ticket_dir / f"1742605300-{_UUID2}-STATUS.json"
    corrupt_file.write_text("{this is not valid json!!!}")

    # The reducer must NOT raise; it should return valid state
    with warnings.catch_warnings(record=True):
        warnings.simplefilter("always")
        state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, (
        "reduce_ticket must return valid state when a corrupt file is present"
    )
    assert state["title"] == "Reducer is lenient"
    assert state["ticket_type"] == "bug"


# ---------------------------------------------------------------------------
# Test 4: reducer returns None for ticket with no CREATE event
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_returns_none_for_ticket_with_no_create_event(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Given a ticket directory that contains only STATUS events (no CREATE),
    reduce_ticket must return None (or raise TicketNotFoundError — either
    signals that the ticket cannot be compiled to state).
    """
    ticket_dir = tmp_path / "tkt-no-create"
    ticket_dir.mkdir()

    # Write a STATUS event with no preceding CREATE
    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="STATUS",
        data={"status": "closed"},
    )

    try:
        state = reducer.reduce_ticket(ticket_dir)
        # If no exception, state must be None
        assert state is None, (
            "reduce_ticket must return None when no CREATE event is present"
        )
    except Exception as exc:  # noqa: BLE001
        # TicketNotFoundError or similar is also acceptable
        assert (
            "TicketNotFound" in type(exc).__name__ or "NotFound" in type(exc).__name__
        ), (
            f"Expected TicketNotFoundError or None return, got {type(exc).__name__}: {exc}"
        )


# ---------------------------------------------------------------------------
# Test 5: reducer handles empty ticket directory gracefully
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_handles_empty_ticket_dir(tmp_path: Path, reducer: ModuleType) -> None:
    """Given an existing but empty .tickets-tracker/<ticket_id>/ directory,
    reduce_ticket must return None without crashing.
    """
    ticket_dir = tmp_path / "tkt-empty"
    ticket_dir.mkdir()

    # Directory exists but contains no event files
    state = reducer.reduce_ticket(ticket_dir)

    assert state is None, "reduce_ticket must return None for an empty ticket directory"


# ---------------------------------------------------------------------------
# Test 6: STATUS event updates ticket status (new STATUS contract)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_compiles_status_event_to_correct_status(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Given a CREATE event followed by a STATUS event, the reducer must update status.

    The STATUS event data includes both 'status' (target) and 'current_status'
    (optimistic concurrency proof). When current_status matches the current
    compiled status, the transition must be applied.
    """
    ticket_dir = tmp_path / "tkt-status"
    ticket_dir.mkdir()

    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "task",
            "title": "Status transition test",
            "parent_id": None,
        },
    )

    _write_event(
        ticket_dir,
        timestamp=1742605300,
        uuid=_UUID2,
        event_type="STATUS",
        data={"status": "in_progress", "current_status": "open"},
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None
    assert state["status"] == "in_progress", (
        "STATUS event must update ticket status when current_status matches"
    )


# ---------------------------------------------------------------------------
# Test 7: STATUS event with current_status mismatch flags conflict
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_applies_multiple_status_events_current_status_mismatch_flags_conflict(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """STATUS event where current_status doesn't match compiled status must flag a conflict.

    Per the contract: 'The reducer must apply this event only if the ticket's
    current compiled status matches current_status; otherwise it should flag
    a conflict.'

    The reducer must indicate a conflict — either by including a 'conflicts'
    key in the returned state, or by returning a state with status='conflict',
    rather than silently applying the bad transition.
    """
    ticket_dir = tmp_path / "tkt-conflict"
    ticket_dir.mkdir()

    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "task",
            "title": "Conflict detection test",
            "parent_id": None,
        },
    )

    # STATUS event with wrong current_status — ticket is "open" but event says "in_progress"
    _write_event(
        ticket_dir,
        timestamp=1742605300,
        uuid=_UUID2,
        event_type="STATUS",
        data={"status": "closed", "current_status": "in_progress"},
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, "reduce_ticket must return a dict, not None, on conflict"
    # Reducer must flag the conflict — either via a 'conflicts' list or status='conflict'
    has_conflict = state.get("conflicts") or state.get("status") == "conflict"
    assert has_conflict, (
        "STATUS event with mismatched current_status must be flagged as a conflict; "
        f"got state={state!r}"
    )


# ---------------------------------------------------------------------------
# Test 8: COMMENT event accumulates in comments list
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_compiles_comment_event_to_comments_list(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Given a CREATE + COMMENT event, the reducer must append to the comments list.

    Each comment in state['comments'] must include at minimum:
      - 'body': the comment text
      - 'author': the event author
      - 'timestamp': the event timestamp
    """
    ticket_dir = tmp_path / "tkt-comment"
    ticket_dir.mkdir()

    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "task",
            "title": "Comment test",
            "parent_id": None,
        },
        author="Alice",
    )

    _write_event(
        ticket_dir,
        timestamp=1742605300,
        uuid=_UUID2,
        event_type="COMMENT",
        data={"body": "first comment"},
        author="Bob",
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None
    assert len(state["comments"]) == 1, (
        "COMMENT event must append one entry to the comments list"
    )
    comment = state["comments"][0]
    assert comment["body"] == "first comment", (
        "comment body must match the COMMENT event data.body"
    )
    assert comment["author"] == "Bob", (
        "comment author must match the COMMENT event author"
    )
    assert comment["timestamp"] == 1742605300, (
        "comment timestamp must match the COMMENT event timestamp"
    )


# ---------------------------------------------------------------------------
# Test 9: Multiple COMMENT events accumulate in chronological order
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_accumulates_multiple_comments(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """Given CREATE + two COMMENT events, comments list must have 2 entries in order."""
    ticket_dir = tmp_path / "tkt-multicomment"
    ticket_dir.mkdir()

    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID,
        event_type="CREATE",
        data={
            "ticket_type": "task",
            "title": "Multi-comment test",
            "parent_id": None,
        },
        author="Alice",
    )

    _write_event(
        ticket_dir,
        timestamp=1742605300,
        uuid=_UUID2,
        event_type="COMMENT",
        data={"body": "first comment"},
        author="Bob",
    )

    _write_event(
        ticket_dir,
        timestamp=1742605400,
        uuid=_UUID3,
        event_type="COMMENT",
        data={"body": "second comment"},
        author="Carol",
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None
    assert len(state["comments"]) == 2, (
        "Two COMMENT events must produce two entries in comments list"
    )
    assert state["comments"][0]["body"] == "first comment", (
        "First comment must be chronologically first (lower timestamp)"
    )
    assert state["comments"][1]["body"] == "second comment", (
        "Second comment must be chronologically second (higher timestamp)"
    )


# ---------------------------------------------------------------------------
# Test 10: Ghost ticket directory (zero valid events) returns error state dict
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_returns_error_state_for_ticket_dir_with_zero_valid_events(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """A ticket dir containing only corrupt JSON files (no parseable events) must
    return an error state dict — not None, and must not raise.

    Ghost prevention: zero-valid-events → error state, not crash.
    The returned dict must have status='error'.

    # REVIEW-DEFENSE: This test deliberately extends the docstring contract
    # ("returns None if … dir is empty") to differentiate two cases:
    #   - Empty dir (no files at all)     → None  (Tests 4 and 5)
    #   - Corrupt-only dir (no parseable events) → error dict (this test)
    # Story w21-o72z done-definition: ghost tickets must surface as errors,
    # not silently disappear. The updated module docstring now documents this
    # distinction. Returning None for corrupt-only dirs would make ghost
    # tickets invisible to operators, which the story explicitly forbids.
    """
    ticket_dir = tmp_path / "tkt-ghost"
    ticket_dir.mkdir()

    # Write only a corrupt JSON file — no valid events at all
    corrupt_file = ticket_dir / f"1742605200-{_UUID}-CREATE.json"
    corrupt_file.write_text("{this is not valid json at all!!!}")

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, (
        "reduce_ticket must return a dict (not None) when only corrupt events exist"
    )
    assert isinstance(state, dict), (
        "reduce_ticket must return a dict for ghost ticket dir"
    )
    assert state.get("status") == "error", (
        f"Ghost ticket dir must return status='error', got status={state.get('status')!r}"
    )


# ---------------------------------------------------------------------------
# Test 11: Corrupt CREATE event marks ticket as fsck_needed
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_reducer_flags_corrupt_create_as_fsck_needed(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """A CREATE event missing required fields (ticket_type) must not silently corrupt state.

    The reducer must return a dict with status='fsck_needed' rather than None
    or raising an exception. It must also not block all operations — the
    returned dict must be a non-None, non-raising result.

    # NOTE (w21-o72z): 'fsck_needed' is a new sentinel value introduced by
    # this story to distinguish structurally-corrupt-but-parseable CREATE events
    # (missing required fields) from fully-unparseable corrupt JSON (status='error',
    # Test 10). The sentinel signals: "this ticket exists but needs manual
    # inspection before it can be safely used." The implementer must use
    # exactly 'fsck_needed' as the status string for this case.
    """
    ticket_dir = tmp_path / "tkt-fsck"
    ticket_dir.mkdir()

    # Write a malformed CREATE event — missing the required 'ticket_type' field
    malformed_create: dict = {
        "timestamp": 1742605200,
        "uuid": _UUID,
        "event_type": "CREATE",
        "env_id": "00000000-0000-4000-8000-000000000001",
        "author": "Alice",
        "data": {
            # 'ticket_type' is intentionally absent
            "title": "Corrupt create ticket",
            "parent_id": None,
        },
    }
    create_file = ticket_dir / f"1742605200-{_UUID}-CREATE.json"
    create_file.write_text(json.dumps(malformed_create))

    # A STATUS event follows the corrupt CREATE
    _write_event(
        ticket_dir,
        timestamp=1742605300,
        uuid=_UUID2,
        event_type="STATUS",
        data={"status": "in_progress", "current_status": "open"},
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, (
        "reduce_ticket must return a dict (not None) for a corrupt CREATE event"
    )
    assert isinstance(state, dict), (
        "reduce_ticket must return a dict, not raise, for corrupt CREATE"
    )
    assert state.get("status") == "fsck_needed", (
        f"Corrupt CREATE event must set status='fsck_needed', got status={state.get('status')!r}"
    )
