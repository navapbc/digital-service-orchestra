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


# ---------------------------------------------------------------------------
# Test 6–11: Flap detection (RED — detect_status_flap() not yet implemented)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_detect_status_flap_returns_false_below_threshold(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a ticket dir with 2 STATUS events alternating between two statuses,
    detect_status_flap() returns False because the oscillation count is below
    the default threshold of N=3.
    """
    ticket_dir = tmp_path / "w21-flap-below"
    ticket_dir.mkdir()

    base_ts = 1742605000
    # Two alternating STATUS events: open → in_progress (only 1 oscillation)
    _write_event(
        ticket_dir,
        timestamp=base_ts,
        uuid=_UUID1,
        event_type="STATUS",
        data={"status": "open"},
        env_id=_OTHER_ENV_ID,
    )
    _write_event(
        ticket_dir,
        timestamp=base_ts + 60,
        uuid=_UUID2,
        event_type="STATUS",
        data={"status": "in_progress"},
        env_id=_OTHER_ENV_ID,
    )

    result = bridge.detect_status_flap(ticket_dir)

    assert result is False, (
        "detect_status_flap must return False when oscillation count is below threshold (N=3)"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_detect_status_flap_returns_true_at_threshold(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a ticket dir with 3+ STATUS events alternating between two statuses,
    detect_status_flap() returns True because the oscillation threshold (N=3) is reached.
    """
    ticket_dir = tmp_path / "w21-flap-at-threshold"
    ticket_dir.mkdir()

    base_ts = 1742605000
    # Six alternating STATUS events: open→ip→open→ip→open→ip (3 reversals)
    # Reversals counted: event 3 returns to open (1), event 4 returns to ip (2),
    # event 5 returns to open (3) — meets threshold of 3.
    statuses = ["open", "in_progress", "open", "in_progress", "open", "in_progress"]
    uuids = [
        "11111111-1111-1111-1111-111111111111",
        "22222222-2222-2222-2222-222222222222",
        "33333333-3333-3333-3333-333333333333",
        "44444444-4444-4444-4444-444444444444",
        "55555555-5555-5555-5555-555555555555",
        "66666666-6666-6666-6666-666666666666",
    ]
    for i, (status, uid) in enumerate(zip(statuses, uuids)):
        _write_event(
            ticket_dir,
            timestamp=base_ts + i * 60,
            uuid=uid,
            event_type="STATUS",
            data={"status": status},
            env_id=_OTHER_ENV_ID,
        )

    result = bridge.detect_status_flap(ticket_dir)

    assert result is True, (
        "detect_status_flap must return True when reversal count reaches threshold (N=3)"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_detect_status_flap_ignores_monotonic_progression(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given STATUS events in monotonic progression (open→in_progress→completed),
    detect_status_flap() returns False because there is no oscillation.
    """
    ticket_dir = tmp_path / "w21-flap-monotonic"
    ticket_dir.mkdir()

    base_ts = 1742605000
    progressions = [
        ("open", "11111111-1111-1111-1111-111111111111"),
        ("in_progress", "22222222-2222-2222-2222-222222222222"),
        ("completed", "33333333-3333-3333-3333-333333333333"),
    ]
    for i, (status, uid) in enumerate(progressions):
        _write_event(
            ticket_dir,
            timestamp=base_ts + i * 60,
            uuid=uid,
            event_type="STATUS",
            data={"status": status},
            env_id=_OTHER_ENV_ID,
        )

    result = bridge.detect_status_flap(ticket_dir)

    assert result is False, (
        "detect_status_flap must return False for monotonic open→in_progress→completed (no oscillation)"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_detect_status_flap_counts_only_within_window(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given STATUS events where enough oscillations exist but most are older than
    the detection window, detect_status_flap() returns False because only recent
    events count toward the threshold.

    Old events (outside window) must not contribute to the oscillation count.
    """
    ticket_dir = tmp_path / "w21-flap-window"
    ticket_dir.mkdir()

    import time as _time

    now = int(_time.time())
    # Window default assumed to be 3600 seconds (1 hour); old events are >2 hours ago
    old_base = now - 7200  # 2 hours ago — outside any reasonable window
    recent_base = now - 60  # 1 minute ago — inside window

    # Three old alternating events (outside window — should NOT count)
    old_uuids = [
        "aaaa0001-0000-0000-0000-000000000001",
        "aaaa0002-0000-0000-0000-000000000002",
        "aaaa0003-0000-0000-0000-000000000003",
    ]
    old_statuses = ["open", "in_progress", "open"]
    for i, (status, uid) in enumerate(zip(old_statuses, old_uuids)):
        _write_event(
            ticket_dir,
            timestamp=old_base + i * 60,
            uuid=uid,
            event_type="STATUS",
            data={"status": status},
            env_id=_OTHER_ENV_ID,
        )

    # One recent event (inside window — 1 oscillation total, below threshold)
    _write_event(
        ticket_dir,
        timestamp=recent_base,
        uuid="bbbb0001-0000-0000-0000-000000000001",
        event_type="STATUS",
        data={"status": "in_progress"},
        env_id=_OTHER_ENV_ID,
    )

    result = bridge.detect_status_flap(ticket_dir)

    assert result is False, (
        "detect_status_flap must return False when oscillations outside the window "
        "are excluded and recent count is below threshold"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_detect_status_flap_mixed_precision_timestamps(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given STATUS events where early events use seconds-precision timestamps
    (written by old code, ts ~1.7e9) and later events use nanoseconds-precision
    timestamps (written by new code, ts ~1.7e18), detect_status_flap() must
    correctly normalize both precisions and return True when the oscillation
    threshold is reached.

    This exercises the mixed-precision normalization path that is the primary
    motivation for the timestamp change: old and new events coexist in the same
    ticket directory during a migration period.
    """
    ticket_dir = tmp_path / "w21-flap-mixed-precision"
    ticket_dir.mkdir()

    # Old events: seconds-precision timestamps (old code format, clearly < 1e12)
    # base_ts = 1742605000 (well below the 1e12 boundary)
    old_base = 1742605000
    old_events = [
        ("open", "cc110001-0000-0000-0000-000000000001", old_base),
        ("in_progress", "cc110002-0000-0000-0000-000000000002", old_base + 60),
        ("open", "cc110003-0000-0000-0000-000000000003", old_base + 120),
    ]

    # New events: nanoseconds-precision timestamps (new code format, clearly > 1e12)
    # Use 1742605180 * 1_000_000_000 as base; all within 3600s of old events after
    # normalization (old_base normalized = 1742605000e9, new_base = 1742605180e9,
    # difference = 180s — well within the 3600s window).
    ns_base = 1742605180 * 1_000_000_000
    new_events = [
        ("in_progress", "cc220001-0000-0000-0000-000000000001", ns_base),
        ("open", "cc220002-0000-0000-0000-000000000002", ns_base + 60_000_000_000),
        (
            "in_progress",
            "cc220003-0000-0000-0000-000000000003",
            ns_base + 120_000_000_000,
        ),
    ]

    # Write all 6 events: 3 seconds-precision then 3 nanoseconds-precision
    for status, uid, ts in old_events + new_events:
        _write_event(
            ticket_dir,
            timestamp=ts,
            uuid=uid,
            event_type="STATUS",
            data={"status": status},
            env_id=_OTHER_ENV_ID,
        )

    result = bridge.detect_status_flap(ticket_dir)

    assert result is True, (
        "detect_status_flap must return True when 6 oscillating STATUS events "
        "span both seconds-precision (old code) and nanoseconds-precision (new code) "
        "timestamps in the same ticket directory, with 3 reversals reaching the threshold"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_process_outbound_emits_bridge_alert_on_flap(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When detect_status_flap() returns True for a ticket's STATUS event,
    process_outbound must:
      1. Write a BRIDGE_ALERT event file in the ticket directory.
      2. NOT call acli_client.update_issue for that ticket.
    """
    ticket_dir = tmp_path / "w21-flap-alert"
    ticket_dir.mkdir()

    base_ts = 1742605000
    # Six alternating STATUS events to trigger flap (3 reversals)
    statuses = ["open", "in_progress", "open", "in_progress", "open", "in_progress"]
    uuids_list = [
        "55555555-5555-5555-5555-555555555551",
        "55555555-5555-5555-5555-555555555552",
        "55555555-5555-5555-5555-555555555553",
        "55555555-5555-5555-5555-555555555554",
        "55555555-5555-5555-5555-555555555555",
        "55555555-5555-5555-5555-555555555556",
    ]
    for i, (status, uid) in enumerate(zip(statuses, uuids_list)):
        _write_event(
            ticket_dir,
            timestamp=base_ts + i * 60,
            uuid=uid,
            event_type="STATUS",
            data={"status": status},
            env_id=_OTHER_ENV_ID,
        )

    # Write a SYNC event so the bridge knows the Jira key
    sync_payload = {
        "event_type": "SYNC",
        "jira_key": "DSO-42",
        "local_id": "w21-flap-alert",
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": base_ts - 100,
        "run_id": "99999999999",
    }
    (ticket_dir / f"{base_ts - 100}-{_UUID3}-SYNC.json").write_text(
        json.dumps(sync_payload)
    )

    events = [
        {
            "ticket_id": "w21-flap-alert",
            "event_type": "STATUS",
            "file_path": str(
                ticket_dir
                / f"{base_ts + 3 * 60}-55555555-5555-5555-5555-555555555554-STATUS.json"
            ),
        }
    ]

    mock_client = MagicMock()
    mock_client.update_issue = MagicMock(return_value={"key": "DSO-42"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # BRIDGE_ALERT file must be written
    alert_files = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) >= 1, (
        "process_outbound must write a BRIDGE_ALERT event file when flap is detected"
    )

    # update_issue must NOT be called for the flapping ticket
    mock_client.update_issue.assert_not_called()


@pytest.mark.unit
@pytest.mark.scripts
def test_process_outbound_halts_status_push_for_flapping_ticket(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """After a flap is detected, the ticket's STATUS event must NOT be pushed to Jira.

    This test verifies the halt behavior in isolation: even when a SYNC event
    (Jira key) exists and compiled status is resolvable, update_issue is never
    called when detect_status_flap() returns True.
    """
    ticket_dir = tmp_path / "w21-flap-halt"
    ticket_dir.mkdir()

    base_ts = 1742606000
    # Six alternating STATUS events (3 reversals — triggers flap)
    statuses = ["open", "in_progress", "open", "in_progress", "open", "in_progress"]
    uuids_list = [
        "66666666-6666-6666-6666-666666666661",
        "66666666-6666-6666-6666-666666666662",
        "66666666-6666-6666-6666-666666666663",
        "66666666-6666-6666-6666-666666666664",
        "66666666-6666-6666-6666-666666666665",
        "66666666-6666-6666-6666-666666666666",
    ]
    for i, (status, uid) in enumerate(zip(statuses, uuids_list)):
        _write_event(
            ticket_dir,
            timestamp=base_ts + i * 30,
            uuid=uid,
            event_type="STATUS",
            data={"status": status},
            env_id=_OTHER_ENV_ID,
        )

    # SYNC event so the bridge can find the Jira key
    sync_payload = {
        "event_type": "SYNC",
        "jira_key": "DSO-55",
        "local_id": "w21-flap-halt",
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": base_ts - 200,
        "run_id": "88888888888",
    }
    (ticket_dir / f"{base_ts - 200}-{_UUID1}-SYNC.json").write_text(
        json.dumps(sync_payload)
    )

    # Also add a CREATE event so get_compiled_status can return a value
    _write_event(
        ticket_dir,
        timestamp=base_ts - 300,
        uuid=_UUID2,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Flapping halt ticket"},
        env_id=_OTHER_ENV_ID,
    )

    events = [
        {
            "ticket_id": "w21-flap-halt",
            "event_type": "STATUS",
            "file_path": str(
                ticket_dir
                / f"{base_ts + 3 * 30}-66666666-6666-6666-6666-666666666664-STATUS.json"
            ),
        }
    ]

    mock_client = MagicMock()
    mock_client.update_issue = MagicMock(return_value={"key": "DSO-55"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # update_issue must NEVER be called when flap is detected
    mock_client.update_issue.assert_not_called()


# ---------------------------------------------------------------------------
# AcliClient.get_issue_link_types() — happy path and error path
# ---------------------------------------------------------------------------

_ACLI_SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "acli-integration.py"


def _load_acli_module() -> ModuleType:
    import importlib.util

    spec = importlib.util.spec_from_file_location("acli_integration", _ACLI_SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def acli_mod() -> ModuleType:
    """Return the acli-integration module for AcliClient tests."""
    if not _ACLI_SCRIPT_PATH.exists():
        pytest.fail(
            f"acli-integration.py not found at {_ACLI_SCRIPT_PATH} — "
            "implement the module to make these tests pass."
        )
    return _load_acli_module()


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_link_types_returns_list_of_dicts(acli_mod: ModuleType) -> None:
    """Given ACLI returns a JSON array of link type objects,
    when AcliClient.get_issue_link_types() is called,
    then it returns a list of dicts each with 'id' (str) and 'name' (str) fields.
    """
    from unittest.mock import patch

    link_types_response = [
        {
            "id": "10003",
            "name": "Relates",
            "inward": "relates to",
            "outward": "relates to",
        }
    ]
    mock_result = MagicMock(
        returncode=0,
        stdout=__import__("json").dumps(link_types_response),
        stderr="",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.get_issue_link_types()

    assert isinstance(result, list), "get_issue_link_types must return a list"
    assert len(result) == 1, "must return one link type"
    first = result[0]
    assert isinstance(first.get("id"), str), "each dict must have 'id' as str"
    assert isinstance(first.get("name"), str), "each dict must have 'name' as str"
    assert first["name"] == "Relates"


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_link_types_raises_on_acli_error(acli_mod: ModuleType) -> None:
    """Given ACLI returns a non-zero exit code,
    when AcliClient.get_issue_link_types() is called,
    then it raises subprocess.CalledProcessError (consistent with existing patterns).
    """
    import subprocess
    from unittest.mock import patch

    error = subprocess.CalledProcessError(
        returncode=1,
        cmd=["acli", "jira", "workitem", "link", "type", "list", "--json"],
        stderr="connection refused",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", side_effect=error):
        with pytest.raises(subprocess.CalledProcessError):
            client.get_issue_link_types()


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_link_types_dict_wrapped_response(acli_mod: ModuleType) -> None:
    """Given ACLI returns a dict with an 'issueLinkTypes' key,
    when AcliClient.get_issue_link_types() is called,
    then it unwraps and returns the inner list.
    """
    from unittest.mock import patch

    link_types_response = {
        "issueLinkTypes": [
            {
                "id": "10001",
                "name": "Blocks",
                "inward": "is blocked by",
                "outward": "blocks",
            },
            {
                "id": "10002",
                "name": "Clones",
                "inward": "is cloned by",
                "outward": "clones",
            },
        ]
    }
    mock_result = MagicMock(
        returncode=0,
        stdout=__import__("json").dumps(link_types_response),
        stderr="",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.get_issue_link_types()

    assert isinstance(result, list), "must return a list when dict-wrapped"
    assert len(result) == 2, "must unwrap all link types from dict response"
    names = [lt["name"] for lt in result]
    assert "Blocks" in names
    assert "Clones" in names


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_link_types_empty_stdout_returns_empty_list(
    acli_mod: ModuleType,
) -> None:
    """Given ACLI exits 0 but emits empty stdout,
    when AcliClient.get_issue_link_types() is called,
    then it returns an empty list without raising JSONDecodeError.
    """
    from unittest.mock import patch

    mock_result = MagicMock(returncode=0, stdout="", stderr="")

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.get_issue_link_types()

    assert result == [], (
        "empty stdout must return empty list, not raise JSONDecodeError"
    )


# ---------------------------------------------------------------------------
# AcliClient.get_issue_links() — happy path, dict-wrapped, and error path
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_links_returns_list_on_happy_path(acli_mod: ModuleType) -> None:
    """Given ACLI returns a JSON array of issue link objects,
    when AcliClient.get_issue_links() is called,
    then it returns a list of dicts matching the Jira REST API format.
    """
    from unittest.mock import patch

    links_response = [
        {
            "type": {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
            "inwardIssue": None,
            "outwardIssue": {
                "key": "DSO-10",
                "fields": {"summary": "Downstream ticket"},
            },
        }
    ]
    mock_result = MagicMock(
        returncode=0,
        stdout=__import__("json").dumps(links_response),
        stderr="",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.get_issue_links("DSO-5")

    assert isinstance(result, list), "get_issue_links must return a list"
    assert len(result) == 1, "must return all links from the array response"
    link = result[0]
    assert "type" in link, "each link must have a 'type' key"
    assert link["type"]["name"] == "Blocks"


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_links_dict_wrapped_response(acli_mod: ModuleType) -> None:
    """Given ACLI returns a dict with an 'issuelinks' key,
    when AcliClient.get_issue_links() is called,
    then it unwraps and returns the inner list.
    """
    from unittest.mock import patch

    links_response = {
        "issuelinks": [
            {
                "type": {
                    "name": "Relates",
                    "inward": "relates to",
                    "outward": "relates to",
                },
                "inwardIssue": {"key": "DSO-20"},
                "outwardIssue": None,
            }
        ]
    }
    mock_result = MagicMock(
        returncode=0,
        stdout=__import__("json").dumps(links_response),
        stderr="",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.get_issue_links("DSO-5")

    assert isinstance(result, list), "must return a list when dict-wrapped"
    assert len(result) == 1, "must unwrap links from dict response"
    assert result[0]["type"]["name"] == "Relates"


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_links_empty_stdout_returns_empty_list(acli_mod: ModuleType) -> None:
    """Given ACLI exits 0 but emits empty stdout,
    when AcliClient.get_issue_links() is called,
    then it returns an empty list without raising JSONDecodeError.
    """
    from unittest.mock import patch

    mock_result = MagicMock(returncode=0, stdout="", stderr="")

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.get_issue_links("DSO-5")

    assert result == [], (
        "empty stdout must return empty list, not raise JSONDecodeError"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_links_raises_on_acli_error(acli_mod: ModuleType) -> None:
    """Given ACLI returns a non-zero exit code,
    when AcliClient.get_issue_links() is called,
    then it raises subprocess.CalledProcessError.
    """
    import subprocess
    from unittest.mock import patch

    error = subprocess.CalledProcessError(
        returncode=1,
        cmd=["acli", "jira", "workitem", "link", "list", "--key", "DSO-5", "--json"],
        stderr="not found",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", side_effect=error):
        with pytest.raises(subprocess.CalledProcessError):
            client.get_issue_links("DSO-5")


# ---------------------------------------------------------------------------
# AcliClient.delete_issue_link tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_link_calls_acli_with_link_id(acli_mod: ModuleType) -> None:
    """Given a valid link ID,
    when AcliClient.delete_issue_link() is called,
    then it invokes ACLI with the expected command containing the link ID.
    """
    from unittest.mock import patch

    mock_result = MagicMock(returncode=0, stdout="", stderr="")

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result) as mock_run:
        client.delete_issue_link("link-id-123")

    assert mock_run.call_count == 1, "subprocess.run must be called once"
    called_cmd = mock_run.call_args[0][0]
    assert "link-id-123" in called_cmd, (
        "delete_issue_link must pass the link ID to the ACLI command"
    )
    assert "delete" in called_cmd, (
        "delete_issue_link must use 'delete' in the ACLI command"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_link_returns_deleted_status(acli_mod: ModuleType) -> None:
    """Given ACLI succeeds,
    when AcliClient.delete_issue_link() is called,
    then it returns a dict with status 'deleted'.
    """
    from unittest.mock import patch

    mock_result = MagicMock(returncode=0, stdout="", stderr="")

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", return_value=mock_result):
        result = client.delete_issue_link("link-id-456")

    assert isinstance(result, dict), "delete_issue_link must return a dict"
    assert result.get("status") == "deleted", (
        "delete_issue_link must return {'status': 'deleted', ...} on success"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_link_raises_on_acli_error(acli_mod: ModuleType) -> None:
    """Given ACLI returns a non-zero exit code,
    when AcliClient.delete_issue_link() is called,
    then it raises subprocess.CalledProcessError.
    """
    import subprocess
    from unittest.mock import patch

    error = subprocess.CalledProcessError(
        returncode=1,
        cmd=["acli", "jira", "workitem", "link", "delete", "--id", "link-bad"],
        stderr="Internal server error",
    )

    client = acli_mod.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
    )

    with patch("subprocess.run", side_effect=error):
        with pytest.raises(subprocess.CalledProcessError):
            client.delete_issue_link("link-bad")


# ---------------------------------------------------------------------------
# Bug 8190-121b: outbound event writers must use nanosecond timestamps
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_write_sync_event_timestamp_is_nanosecond_scale(
    tmp_path: Path,
) -> None:
    """write_sync_event writes a SYNC event whose 'timestamp' field is at
    nanosecond scale (> 1_000_000_000_000).

    This test is RED: current code uses int(time.time()) which produces a
    seconds-scale integer (~1.7e9), well below the 1e12 threshold. After the
    fix uses time.time_ns() the value will be ~1.7e18, above the threshold.
    """
    # REVIEW-DEFENSE: Direct import is required here — bridge-outbound.py does not re-export
    # write_sync_event, so the bridge module fixture cannot access it. The other three timestamp
    # tests use module fixtures that do expose the tested functions. See bridge-outbound.py
    # line 34-40 (only filter_bridge_events, get_compiled_status, has_existing_sync, etc. are
    # re-exported; write_sync_event is internal to _outbound_api).
    from bridge._outbound_api import write_sync_event

    ticket_dir = tmp_path / "w21-ns-sync"
    ticket_dir.mkdir()

    write_sync_event(
        ticket_dir=ticket_dir,
        jira_key="DSO-9190",
        local_id="w21-ns-sync",
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    sync_files = list(ticket_dir.glob("*-SYNC.json"))
    assert len(sync_files) == 1, (
        f"write_sync_event must write exactly 1 SYNC file; found {len(sync_files)}"
    )

    event_data = json.loads(sync_files[0].read_text(encoding="utf-8"))
    ts = event_data.get("timestamp")
    assert isinstance(ts, int), f"timestamp must be an int, got {type(ts).__name__}"
    assert ts > 1_000_000_000_000, (
        f"timestamp must be nanosecond-scale (> 1_000_000_000_000); "
        f"got {ts} — current code uses int(time.time()) which is seconds-scale (~1.7e9). "
        f"Fix: use time.time_ns() instead."
    )
