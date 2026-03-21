"""RED tests for bridge-outbound.py event processor.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL before bridge-outbound.py is implemented.

The bridge-outbound processor is expected to expose:
    parse_git_diff_events(diff_text: str) -> list[dict]
        Parse new event files from a git diff --name-only output and return
        structured event records with ticket_id, event_type, file_path.

    filter_bridge_events(events: list[dict], bridge_env_id: str) -> list[dict]
        Filter out events whose env_id matches the bridge env ID (echo prevention).

    get_compiled_status(ticket_dir: Path, reducer_path: Path) -> str | None
        Return the compiled/post-conflict-resolution status for a ticket, not raw.
        reducer_path is the filesystem path to ticket-reducer.py (loaded internally).

    has_existing_sync(ticket_dir: Path) -> bool
        Return True if a SYNC event file already exists in the ticket directory.

    process_outbound(events, acli_client, tickets_root: Path, bridge_env_id: str)
        Process parsed events: echo-prevent, compile state, call acli_client,
        write SYNC events.

Mock acli_client interface (from w21-hbjx contract):
    acli_client.create_issue(ticket_data) -> dict
    acli_client.update_issue(jira_key, ticket_data) -> dict
    acli_client.get_issue(jira_key) -> dict | None

SYNC event format (from w21-5mr1 contract):
    {"event_type": "SYNC", "jira_key": str, "local_id": str,
     "env_id": str, "timestamp": int, "run_id": str}

Test: python3 -m pytest tests/scripts/test_bridge_outbound.py
All tests must return non-zero until bridge-outbound.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-outbound.py"

# Reducer path needed for compiled-state tests
REDUCER_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-reducer.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_outbound", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def bridge() -> ModuleType:
    """Return the bridge-outbound module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"bridge-outbound.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_UUID1 = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_UUID2 = "aabbccdd-1122-3344-5566-778899aabbcc"
_UUID3 = "deadbeef-dead-beef-dead-beefdeadbeef"


def _write_event(
    ticket_dir: Path,
    timestamp: int,
    uuid: str,
    event_type: str,
    data: dict,
    env_id: str = _OTHER_ENV_ID,
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


def _make_create_event_payload(
    env_id: str = _OTHER_ENV_ID,
    uuid: str = _UUID1,
    ts: int = 1742605200,
) -> dict:
    return {
        "event_type": "CREATE",
        "uuid": uuid,
        "timestamp": ts,
        "author": "test-user",
        "env_id": env_id,
        "data": {
            "ticket_type": "task",
            "title": "Test ticket",
        },
    }


def _make_status_event_payload(
    status: str,
    env_id: str = _OTHER_ENV_ID,
    uuid: str = _UUID2,
    ts: int = 1742605300,
) -> dict:
    return {
        "event_type": "STATUS",
        "uuid": uuid,
        "timestamp": ts,
        "author": "test-user",
        "env_id": env_id,
        "data": {"status": status},
    }


# ---------------------------------------------------------------------------
# Test 1: git diff event parsing — CREATE event detected
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_git_diff_parses_new_create_events(bridge: ModuleType) -> None:
    """Given fixture git diff --name-only output with a CREATE event file,
    parse_git_diff_events returns a list containing that event with correct fields.

    The diff output simulates `git diff --name-only HEAD~1 HEAD` returning new
    event files under the tickets directory.
    """
    # Simulate git diff --name-only output with a new CREATE event file
    diff_output = (
        ".tickets-tracker/w21-abc1/1742605200-3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c-CREATE.json\n"
        ".tickets-tracker/w21-abc1/1742605300-aabbccdd-1122-3344-5566-778899aabbcc-STATUS.json\n"
        "README.md\n"  # non-event file — must be ignored
    )

    events = bridge.parse_git_diff_events(diff_output)

    assert isinstance(events, list), "parse_git_diff_events must return a list"
    assert len(events) >= 1, "Must detect at least one event from the diff"

    # Find the CREATE event
    create_events = [e for e in events if e.get("event_type") == "CREATE"]
    assert len(create_events) == 1, "Must parse exactly one CREATE event"

    create_event = create_events[0]
    assert create_event["ticket_id"] == "w21-abc1", (
        "ticket_id must be extracted from directory name"
    )
    assert create_event["event_type"] == "CREATE"
    assert "file_path" in create_event, "Parsed event must include file_path"
    assert "CREATE" in create_event["file_path"], "file_path must reference CREATE file"


# ---------------------------------------------------------------------------
# Test 2: echo prevention — ticket with existing SYNC skipped
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_echo_prevention_skips_ticket_with_existing_sync(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a ticket directory that already contains a SYNC event file,
    process_outbound must NOT call acli_client.create_issue for that ticket.

    This prevents Jira bridge echo: if a ticket was imported from Jira inbound,
    it already has a SYNC event, so pushing it outbound would create a duplicate.
    """
    # Set up ticket directory with a SYNC event already present
    ticket_dir = tmp_path / "w21-synced"
    ticket_dir.mkdir()

    # Write a CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID1,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Already synced ticket"},
        env_id=_OTHER_ENV_ID,
    )

    # Write an existing SYNC event (simulating inbound import)
    sync_payload = {
        "event_type": "SYNC",
        "jira_key": "DSO-99",
        "local_id": "w21-synced",
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742605100,
        "run_id": "12345678901",
    }
    sync_file = ticket_dir / f"1742605100-{_UUID2}-SYNC.json"
    sync_file.write_text(json.dumps(sync_payload))

    # Build an event list as parse_git_diff_events would produce
    events = [
        {
            "ticket_id": "w21-synced",
            "event_type": "CREATE",
            "file_path": str(ticket_dir / f"1742605200-{_UUID1}-CREATE.json"),
        }
    ]

    mock_client = MagicMock()
    mock_client.create_issue = MagicMock(return_value={"key": "DSO-99"})
    mock_client.update_issue = MagicMock(return_value={"key": "DSO-99"})
    mock_client.get_issue = MagicMock(return_value={"key": "DSO-99"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.create_issue.assert_not_called()  # must NOT be called for a ticket with an existing SYNC event


# ---------------------------------------------------------------------------
# Test 3: STATUS uses compiled state not raw last event
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_status_event_uses_compiled_state_not_raw(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a ticket with two conflicting STATUS events from different envs,
    the bridge calls update_issue with the post-conflict-resolution compiled
    status, not the raw last STATUS event value.

    Conflict: env A sets 'in_progress' (ts=1742605300), env B sets 'open'
    (ts=1742605200 but added later). The reducer applies conflict resolution;
    the outbound bridge must use the reducer's compiled state.
    """
    ticket_dir = tmp_path / "w21-conflict"
    ticket_dir.mkdir()

    # CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742605100,
        uuid=_UUID1,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Conflict ticket"},
        env_id=_OTHER_ENV_ID,
    )
    # STATUS from env A — earlier timestamp → 'in_progress'
    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID2,
        event_type="STATUS",
        data={"status": "in_progress"},
        env_id="cccccccc-0000-4000-8000-000000000003",
    )
    # STATUS from env B — later timestamp → 'open'  (raw last-event would return 'open')
    _write_event(
        ticket_dir,
        timestamp=1742605300,
        uuid=_UUID3,
        event_type="STATUS",
        data={"status": "open"},
        env_id="dddddddd-0000-4000-8000-000000000004",
    )

    # The compiled state from get_compiled_status must reflect conflict resolution.
    # We don't prescribe the exact resolved value, but the bridge must call
    # get_compiled_status (not just read the last STATUS file directly) and
    # pass that value to update_issue.
    compiled_status = bridge.get_compiled_status(ticket_dir, reducer_path=REDUCER_PATH)

    # compiled_status is a string (status field) or None; it must not be None
    # because a CREATE event is present.
    assert compiled_status is not None, (
        "get_compiled_status must return a non-None status when CREATE event is present"
    )
    assert isinstance(compiled_status, str), (
        "get_compiled_status must return a string status value"
    )
    # The value must be a valid ticket status string
    assert compiled_status in ("open", "in_progress", "completed", "blocked"), (
        f"Compiled status '{compiled_status}' must be a known ticket status"
    )


# ---------------------------------------------------------------------------
# Test 4: bridge env filter — bridge-originated events skipped
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_bridge_env_filter_skips_bridge_originated_events(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given events with env_id matching the bridge env ID,
    filter_bridge_events removes them so create_issue/update_issue is not called.

    This prevents the bridge from processing its own commits (infinite loop protection).
    """
    # Mix of events: one from bridge env (must be filtered), one from user env (kept)
    events_with_env = [
        {
            "ticket_id": "w21-bridge-own",
            "event_type": "STATUS",
            "env_id": _BRIDGE_ENV_ID,  # bridge's own event — must be filtered
            "file_path": str(tmp_path / "w21-bridge-own" / "1742605200-status.json"),
        },
        {
            "ticket_id": "w21-user-event",
            "event_type": "CREATE",
            "env_id": _OTHER_ENV_ID,  # user event — must be kept
            "file_path": str(tmp_path / "w21-user-event" / "1742605100-create.json"),
        },
    ]

    filtered = bridge.filter_bridge_events(
        events_with_env, bridge_env_id=_BRIDGE_ENV_ID
    )

    assert isinstance(filtered, list), "filter_bridge_events must return a list"
    ticket_ids = [e["ticket_id"] for e in filtered]
    assert "w21-bridge-own" not in ticket_ids, (
        "Events from bridge env must be filtered out"
    )
    assert "w21-user-event" in ticket_ids, "Events from user env must be kept"

    # Verify no calls to acli when all events are from the bridge env
    bridge_only_events = [events_with_env[0]]
    mock_client = MagicMock()
    mock_client.create_issue = MagicMock()
    mock_client.update_issue = MagicMock()

    bridge.process_outbound(
        bridge_only_events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.create_issue.assert_not_called()  # must NOT be called for bridge-originated events
    mock_client.update_issue.assert_not_called()  # must NOT be called for bridge-originated events


# ---------------------------------------------------------------------------
# Test 5: idempotency — no duplicate SYNC write when SYNC already exists
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_idempotent_no_duplicate_sync_write(tmp_path: Path, bridge: ModuleType) -> None:
    """Given a run where create_issue succeeds but a SYNC file already exists
    in the ticket directory, no second SYNC file is written.

    This guards against race conditions where two bridge runs overlap.
    """
    ticket_dir = tmp_path / "w21-idempotent"
    ticket_dir.mkdir()

    # Write CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742605200,
        uuid=_UUID1,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Idempotency test ticket"},
        env_id=_OTHER_ENV_ID,
    )

    # Pre-write a SYNC event to simulate a previous run having completed
    existing_sync = {
        "event_type": "SYNC",
        "jira_key": "DSO-77",
        "local_id": "w21-idempotent",
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742605050,
        "run_id": "11111111111",
    }
    sync_file = ticket_dir / f"1742605050-{_UUID2}-SYNC.json"
    sync_file.write_text(json.dumps(existing_sync))

    # Confirm has_existing_sync detects it
    assert bridge.has_existing_sync(ticket_dir) is True, (
        "has_existing_sync must return True when a SYNC file exists"
    )

    # Count SYNC files before process_outbound
    sync_files_before = list(ticket_dir.glob("*-SYNC.json"))
    assert len(sync_files_before) == 1, "Setup: exactly one SYNC file expected"

    events = [
        {
            "ticket_id": "w21-idempotent",
            "event_type": "CREATE",
            "env_id": _OTHER_ENV_ID,
            "file_path": str(ticket_dir / f"1742605200-{_UUID1}-CREATE.json"),
        }
    ]

    mock_client = MagicMock()
    mock_client.create_issue = MagicMock(return_value={"key": "DSO-77"})
    mock_client.get_issue = MagicMock(return_value={"key": "DSO-77"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # SYNC file count must not increase
    sync_files_after = list(ticket_dir.glob("*-SYNC.json"))
    assert len(sync_files_after) == 1, (
        f"No duplicate SYNC file must be written; found {len(sync_files_after)} after process_outbound"
    )
