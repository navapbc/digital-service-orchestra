"""RED tests for REVERT check-before-overwrite in bridge-outbound.py.

These tests are RED — they define expected behavior for REVERT event handling
that does not yet exist in bridge-outbound.py. All tests must FAIL before the
implementation in bridge-outbound.py is added.

Contract reference: plugins/dso/docs/contracts/revert-event.md
Section: Bridge-Outbound Semantics (Check-Before-Overwrite)

When bridge-outbound processes a REVERT whose data.target_event_type is STATUS:
1. Fetch current Jira state (get_issue) BEFORE pushing the revert effect.
2. Compare fetched state against state recorded at the original bad action.
3. If Jira has diverged → emit BRIDGE_ALERT, do NOT push.
4. If Jira has not diverged → push the revert (update_issue with previous status).

Test: python3 -m pytest tests/scripts/test_bridge_outbound_revert.py -v
All tests must return FAILED/ERROR until bridge-outbound.py implements REVERT handling.
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
# Constants and helpers
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"

# Fixed UUIDs for events (deterministic)
_UUID_CREATE = "11111111-0001-4000-8000-000000000001"
_UUID_STATUS_OPEN = "22222222-0002-4000-8000-000000000002"
_UUID_STATUS_CLOSED = "33333333-0003-4000-8000-000000000003"
_UUID_REVERT = "44444444-0004-4000-8000-000000000004"
_UUID_SYNC = "55555555-0005-4000-8000-000000000005"
_UUID_STATUS_IN_PROGRESS = "66666666-0006-4000-8000-000000000006"

_JIRA_KEY = "DSO-101"


def _write_event(
    ticket_dir: Path,
    timestamp: int,
    event_uuid: str,
    event_type: str,
    data: dict,
    env_id: str = _OTHER_ENV_ID,
    author: str = "Test User",
) -> Path:
    """Write a well-formed event JSON file and return its path."""
    filename = f"{timestamp}-{event_uuid}-{event_type}.json"
    payload = {
        "timestamp": timestamp,
        "uuid": event_uuid,
        "event_type": event_type,
        "env_id": env_id,
        "author": author,
        "data": data,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _write_sync_event(
    ticket_dir: Path,
    jira_key: str,
    local_id: str,
    timestamp: int = 1742605100,
    sync_uuid: str = _UUID_SYNC,
    env_id: str = _BRIDGE_ENV_ID,
) -> Path:
    """Write a SYNC event to the ticket directory and return its path."""
    filename = f"{timestamp}-{sync_uuid}-SYNC.json"
    payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": local_id,
        "env_id": env_id,
        "timestamp": timestamp,
        "run_id": "test-run-001",
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _build_revert_event_list(
    ticket_id: str,
    ticket_dir: Path,
    revert_uuid: str,
    revert_ts: int,
    target_event_uuid: str,
    target_event_type: str,
    reason: str = "",
) -> list[dict]:
    """Build an event list containing one REVERT entry (as process_outbound receives)."""
    revert_filename = f"{revert_ts}-{revert_uuid}-REVERT.json"
    return [
        {
            "ticket_id": ticket_id,
            "event_type": "REVERT",
            "file_path": str(ticket_dir / revert_filename),
        }
    ]


# ---------------------------------------------------------------------------
# Test 1: REVERT processing fetches Jira state before pushing
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_process_outbound_revert_fetches_jira_state_before_push(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When processing a REVERT event targeting a STATUS event, bridge-outbound
    must call acli_client.get_issue() with the ticket's jira_key BEFORE any
    update call is made.

    Setup:
    - Ticket has: CREATE + STATUS(closed) + REVERT(targeting STATUS)
    - SYNC event is present so bridge knows the Jira key
    - REVERT event file exists on disk

    Assert: get_issue() is called with the jira_key at some point during processing.
    """
    ticket_id = "w21-revert-fetch"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir()

    base_ts = 1742605000

    # CREATE event
    _write_event(
        ticket_dir,
        timestamp=base_ts,
        event_uuid=_UUID_CREATE,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Revert fetch test"},
        env_id=_OTHER_ENV_ID,
    )

    # STATUS event (bad action — moved to closed)
    _write_event(
        ticket_dir,
        timestamp=base_ts + 100,
        event_uuid=_UUID_STATUS_CLOSED,
        event_type="STATUS",
        data={"status": "closed"},
        env_id=_OTHER_ENV_ID,
    )

    # SYNC event so bridge knows jira_key
    _write_sync_event(
        ticket_dir, jira_key=_JIRA_KEY, local_id=ticket_id, timestamp=base_ts + 50
    )

    # REVERT event targeting the STATUS(closed) event
    revert_ts = base_ts + 200
    revert_event_path = ticket_dir / f"{revert_ts}-{_UUID_REVERT}-REVERT.json"
    revert_payload = {
        "event_type": "REVERT",
        "timestamp": revert_ts,
        "uuid": _UUID_REVERT,
        "env_id": _OTHER_ENV_ID,
        "author": "Test User",
        "data": {
            "target_event_uuid": _UUID_STATUS_CLOSED,
            "target_event_type": "STATUS",
            "reason": "Status was advanced to closed prematurely",
        },
    }
    revert_event_path.write_text(json.dumps(revert_payload))

    events = _build_revert_event_list(
        ticket_id=ticket_id,
        ticket_dir=ticket_dir,
        revert_uuid=_UUID_REVERT,
        revert_ts=revert_ts,
        target_event_uuid=_UUID_STATUS_CLOSED,
        target_event_type="STATUS",
        reason="Status was advanced to closed prematurely",
    )

    mock_client = MagicMock()
    # get_issue returns current Jira state matching the bad action state (no divergence)
    mock_client.get_issue.return_value = {"key": _JIRA_KEY, "status": "closed"}
    mock_client.update_issue.return_value = {"key": _JIRA_KEY}

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Assert: get_issue was called with the ticket's jira_key
    mock_client.get_issue.assert_called()
    call_args_list = mock_client.get_issue.call_args_list
    jira_keys_fetched = [
        args[0] if args else kwargs.get("jira_key", kwargs.get("key", ""))
        for args, kwargs in [(c.args, c.kwargs) for c in call_args_list]
    ]
    assert any(_JIRA_KEY in str(arg) for arg in jira_keys_fetched), (
        f"get_issue must be called with jira_key '{_JIRA_KEY}' before any update; "
        f"calls were: {call_args_list}"
    )


# ---------------------------------------------------------------------------
# Test 2: REVERT emits BRIDGE_ALERT when Jira state has diverged
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_process_outbound_revert_emits_bridge_alert_when_jira_diverged(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When processing a REVERT and get_issue() returns a status different from
    the one recorded at the original bad action, bridge-outbound must:
    1. Write a BRIDGE_ALERT event file to the ticket directory.
    2. Include 'diverged' or 'Jira state has changed' in the BRIDGE_ALERT reason.
    3. NOT call update_issue (do not push the revert).

    Setup:
    - Ticket has: CREATE + STATUS(open→closed) + REVERT(targeting STATUS(closed))
    - get_issue() returns status='in_progress' — Jira has been changed since the
      bad action was recorded, so Jira has diverged from the expected state.

    Assert: BRIDGE_ALERT file written; reason mentions divergence; no update call.
    """
    ticket_id = "w21-revert-diverged"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir()

    base_ts = 1742606000

    # CREATE event
    _write_event(
        ticket_dir,
        timestamp=base_ts,
        event_uuid=_UUID_CREATE,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Revert diverge test"},
        env_id=_OTHER_ENV_ID,
    )

    # STATUS event — bad action (moved to closed)
    _write_event(
        ticket_dir,
        timestamp=base_ts + 100,
        event_uuid=_UUID_STATUS_CLOSED,
        event_type="STATUS",
        data={"status": "closed"},
        env_id=_OTHER_ENV_ID,
    )

    # SYNC event so bridge knows jira_key
    _write_sync_event(
        ticket_dir, jira_key=_JIRA_KEY, local_id=ticket_id, timestamp=base_ts + 50
    )

    # REVERT event targeting the STATUS(closed) event
    revert_ts = base_ts + 200
    revert_event_path = ticket_dir / f"{revert_ts}-{_UUID_REVERT}-REVERT.json"
    revert_payload = {
        "event_type": "REVERT",
        "timestamp": revert_ts,
        "uuid": _UUID_REVERT,
        "env_id": _OTHER_ENV_ID,
        "author": "Test User",
        "data": {
            "target_event_uuid": _UUID_STATUS_CLOSED,
            "target_event_type": "STATUS",
            "reason": "Premature closure",
        },
    }
    revert_event_path.write_text(json.dumps(revert_payload))

    events = _build_revert_event_list(
        ticket_id=ticket_id,
        ticket_dir=ticket_dir,
        revert_uuid=_UUID_REVERT,
        revert_ts=revert_ts,
        target_event_uuid=_UUID_STATUS_CLOSED,
        target_event_type="STATUS",
        reason="Premature closure",
    )

    mock_client = MagicMock()
    # Jira has diverged — returns 'in_progress' instead of 'closed' (the bad action's state)
    mock_client.get_issue.return_value = {"key": _JIRA_KEY, "status": "in_progress"}
    mock_client.update_issue.return_value = {"key": _JIRA_KEY}

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Assert: BRIDGE_ALERT file was written
    alert_files = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) >= 1, (
        "process_outbound must write a BRIDGE_ALERT event file when Jira state has diverged "
        f"since the original bad action. Found {len(alert_files)} BRIDGE_ALERT files."
    )

    # Assert: BRIDGE_ALERT reason mentions 'diverged' or 'Jira state has changed'
    alert_data = json.loads(alert_files[0].read_text())
    reason = alert_data.get("data", {}).get("reason", "") or alert_data.get(
        "reason", ""
    )
    assert any(
        kw in reason.lower() for kw in ("diverged", "jira state has changed", "changed")
    ), (
        f"BRIDGE_ALERT reason must mention 'diverged' or 'Jira state has changed'; "
        f"got: '{reason}'"
    )

    # Assert: update_issue was NOT called (revert must not be pushed on divergence)
    mock_client.update_issue.assert_not_called()


# ---------------------------------------------------------------------------
# Test 3: REVERT proceeds (no alert) when Jira state matches expected
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_process_outbound_revert_proceeds_when_jira_state_matches(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When processing a REVERT and get_issue() returns the expected current Jira
    state (matching the bad action state — no divergence), bridge-outbound must:
    1. NOT write a BRIDGE_ALERT event file.
    2. Call update_issue (push the revert effect to Jira).

    Setup:
    - Ticket has: CREATE + STATUS(closed) + REVERT(targeting STATUS(closed))
    - get_issue() returns status='closed' — matches the bad action; no divergence.

    Assert: no BRIDGE_ALERT written; update_issue called.
    """
    ticket_id = "w21-revert-match"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir()

    base_ts = 1742607000

    # CREATE event
    _write_event(
        ticket_dir,
        timestamp=base_ts,
        event_uuid=_UUID_CREATE,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Revert match test"},
        env_id=_OTHER_ENV_ID,
    )

    # Previous STATUS (open — the state before the bad action)
    _write_event(
        ticket_dir,
        timestamp=base_ts + 50,
        event_uuid=_UUID_STATUS_OPEN,
        event_type="STATUS",
        data={"status": "open"},
        env_id=_OTHER_ENV_ID,
    )

    # Bad action STATUS (closed)
    _write_event(
        ticket_dir,
        timestamp=base_ts + 100,
        event_uuid=_UUID_STATUS_CLOSED,
        event_type="STATUS",
        data={"status": "closed"},
        env_id=_OTHER_ENV_ID,
    )

    # SYNC event so bridge knows jira_key
    _write_sync_event(
        ticket_dir, jira_key=_JIRA_KEY, local_id=ticket_id, timestamp=base_ts + 60
    )

    # REVERT event targeting the STATUS(closed) event
    revert_ts = base_ts + 200
    revert_event_path = ticket_dir / f"{revert_ts}-{_UUID_REVERT}-REVERT.json"
    revert_payload = {
        "event_type": "REVERT",
        "timestamp": revert_ts,
        "uuid": _UUID_REVERT,
        "env_id": _OTHER_ENV_ID,
        "author": "Test User",
        "data": {
            "target_event_uuid": _UUID_STATUS_CLOSED,
            "target_event_type": "STATUS",
            "reason": "Reverting premature close",
        },
    }
    revert_event_path.write_text(json.dumps(revert_payload))

    events = _build_revert_event_list(
        ticket_id=ticket_id,
        ticket_dir=ticket_dir,
        revert_uuid=_UUID_REVERT,
        revert_ts=revert_ts,
        target_event_uuid=_UUID_STATUS_CLOSED,
        target_event_type="STATUS",
        reason="Reverting premature close",
    )

    mock_client = MagicMock()
    # Jira state matches the bad action state — no divergence
    mock_client.get_issue.return_value = {"key": _JIRA_KEY, "status": "closed"}
    mock_client.update_issue.return_value = {"key": _JIRA_KEY}

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Assert: no BRIDGE_ALERT written (Jira has not diverged)
    alert_files = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) == 0, (
        f"process_outbound must NOT write a BRIDGE_ALERT when Jira state matches expected; "
        f"found {len(alert_files)} BRIDGE_ALERT file(s)"
    )

    # Assert: update_issue was called (the revert effect was pushed)
    mock_client.update_issue.assert_called()


# ---------------------------------------------------------------------------
# Test 4: REVERT of STATUS event pushes the previous (pre-bad-action) status
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_process_outbound_revert_of_status_event_pushes_previous_status(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When reverting a STATUS event, bridge-outbound must push the status value
    from the event BEFORE the bad action — i.e., the previous status.

    Event chain:
    - STATUS(open→in_progress) [ts=base+100, uuid=UUID_STATUS_OPEN]
    - STATUS(in_progress→closed) [ts=base+200, uuid=UUID_STATUS_CLOSED] ← bad action
    - REVERT targeting STATUS(closed) [ts=base+300]

    Expected outbound effect: update_issue called with status='in_progress'
    (the status before the bad action was applied).

    get_issue() returns status='closed' (Jira still at bad action state; no divergence).
    """
    ticket_id = "w21-revert-prev-status"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir()

    base_ts = 1742608000

    # CREATE event
    _write_event(
        ticket_dir,
        timestamp=base_ts,
        event_uuid=_UUID_CREATE,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Revert previous status test"},
        env_id=_OTHER_ENV_ID,
    )

    # First STATUS: open → in_progress (good action)
    _write_event(
        ticket_dir,
        timestamp=base_ts + 100,
        event_uuid=_UUID_STATUS_IN_PROGRESS,
        event_type="STATUS",
        data={"status": "in_progress"},
        env_id=_OTHER_ENV_ID,
    )

    # Second STATUS: in_progress → closed (bad action)
    _write_event(
        ticket_dir,
        timestamp=base_ts + 200,
        event_uuid=_UUID_STATUS_CLOSED,
        event_type="STATUS",
        data={"status": "closed"},
        env_id=_OTHER_ENV_ID,
    )

    # SYNC event so bridge knows jira_key
    _write_sync_event(
        ticket_dir, jira_key=_JIRA_KEY, local_id=ticket_id, timestamp=base_ts + 50
    )

    # REVERT event targeting the STATUS(closed) bad action
    revert_ts = base_ts + 300
    revert_event_path = ticket_dir / f"{revert_ts}-{_UUID_REVERT}-REVERT.json"
    revert_payload = {
        "event_type": "REVERT",
        "timestamp": revert_ts,
        "uuid": _UUID_REVERT,
        "env_id": _OTHER_ENV_ID,
        "author": "Test User",
        "data": {
            "target_event_uuid": _UUID_STATUS_CLOSED,
            "target_event_type": "STATUS",
            "reason": "Status was advanced to closed prematurely; reverting to in_progress",
        },
    }
    revert_event_path.write_text(json.dumps(revert_payload))

    events = _build_revert_event_list(
        ticket_id=ticket_id,
        ticket_dir=ticket_dir,
        revert_uuid=_UUID_REVERT,
        revert_ts=revert_ts,
        target_event_uuid=_UUID_STATUS_CLOSED,
        target_event_type="STATUS",
        reason="Status was advanced to closed prematurely; reverting to in_progress",
    )

    mock_client = MagicMock()
    # Jira state matches the bad action state — no divergence; proceed with revert
    mock_client.get_issue.return_value = {"key": _JIRA_KEY, "status": "closed"}
    mock_client.update_issue.return_value = {"key": _JIRA_KEY}

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Assert: update_issue was called with status='in_progress' (the pre-bad-action status)
    mock_client.update_issue.assert_called()
    update_calls = mock_client.update_issue.call_args_list
    # The call must include status='in_progress' somewhere in args or kwargs
    status_values_pushed = []
    for c in update_calls:
        args, kwargs = c.args, c.kwargs
        if "status" in kwargs:
            status_values_pushed.append(kwargs["status"])
        # Also check positional dict args
        for a in args:
            if isinstance(a, dict) and "status" in a:
                status_values_pushed.append(a["status"])

    assert "in_progress" in status_values_pushed, (
        f"update_issue must be called with status='in_progress' (the previous status before "
        f"the bad action); actual status values pushed: {status_values_pushed}. "
        f"Full call list: {update_calls}"
    )
