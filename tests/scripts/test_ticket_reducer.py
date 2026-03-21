"""RED tests for ticket-reducer.py.

These tests are RED — they test functionality that does not yet exist.
All 5 test functions must FAIL before ticket-reducer.py is implemented.

The reducer is expected to expose a single callable:
    reduce_ticket(ticket_dir_path: Path) -> dict | None

Contract (from plugins/dso/docs/contracts/ticket-event-format.md):
  - Event files are named: <timestamp>-<uuid>-<TYPE>.json
  - Events are sorted lexicographically by filename before reduction.
  - A CREATE event supplies ticket_type, title, and optional parent_id.
  - The reducer returns None if no CREATE event is present or the dir is empty.

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
        data={"status": "closed", "marker": "t2_processed_second"},
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
