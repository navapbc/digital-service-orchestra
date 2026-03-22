"""RED tests for REVERT event writing, CLI validation, and reducer handling.

These tests are RED — they define expected behavior for REVERT events before
the implementations exist. All test functions must FAIL before:
  - ticket-revert.sh is created
  - REVERT is added to ticket-lib.sh allowed event types
  - ticket-reducer.py is updated to handle REVERT events

Contract: plugins/dso/docs/contracts/revert-event.md

Tests cover:
  1. ticket-revert.sh writes a REVERT event file with correct fields
  2. REVERT-of-REVERT is rejected by the CLI
  3. Nonexistent target UUID is rejected by the CLI
  4. Reducer records reverts in compiled state (reverts list)
  5. Reducer does NOT automatically undo status when a REVERT targets a STATUS event

Test: python3 -m pytest tests/scripts/test_revert_event.py -v
All tests must return FAILED or ERROR until implementations are provided.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
)
TICKET_CMD = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket"
REDUCER_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "ticket-reducer.py"

# ---------------------------------------------------------------------------
# Module loading helpers
# ---------------------------------------------------------------------------


def _load_reducer() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ticket_reducer", REDUCER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def reducer() -> ModuleType:
    """Return the ticket-reducer module, failing all tests if absent (RED)."""
    if not REDUCER_PATH.exists():
        pytest.fail(
            f"ticket-reducer.py not found at {REDUCER_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_reducer()


# ---------------------------------------------------------------------------
# Shared UUIDs and helpers
# ---------------------------------------------------------------------------

_ENV_ID = "00000000-0000-4000-8000-000000000001"
_CREATE_UUID = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
_STATUS_UUID = "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
_REVERT_UUID = "cccccccc-cccc-4ccc-cccc-cccccccccccc"


def _write_event(
    ticket_dir: Path,
    timestamp: int,
    uuid: str,
    event_type: str,
    data: dict,
    env_id: str = _ENV_ID,
    author: str = "Test User",
) -> Path:
    """Write a well-formed event JSON file and return its path."""
    filename = f"{timestamp}-{uuid}-{event_type}.json"
    payload = {
        "event_type": event_type,
        "timestamp": timestamp,
        "uuid": uuid,
        "env_id": env_id,
        "author": author,
        "data": data,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _setup_tracker(tmp_path: Path, ticket_id: str = "tkt-rev-001") -> Path:
    """Create a .tickets-tracker dir with env-id and return it."""
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir(parents=True)
    env_id_file = tracker_dir / ".env-id"
    env_id_file.write_text(_ENV_ID)
    return tracker_dir


def _run_ticket_revert(
    tracker_dir: Path,
    ticket_id: str,
    target_uuid: str,
    reason: str = "",
    extra_args: list[str] | None = None,
) -> subprocess.CompletedProcess:
    """Invoke 'ticket revert <ticket_id> <target_uuid>' with TICKETS_TRACKER_DIR set."""
    env = {
        **os.environ,
        "TICKETS_TRACKER_DIR": str(tracker_dir),
        "GIT_DIR": str(REPO_ROOT / ".git"),
    }
    cmd = ["bash", str(TICKET_CMD), "revert", ticket_id, target_uuid]
    if reason:
        cmd.append(f"--reason={reason}")
    if extra_args:
        cmd.extend(extra_args)
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
        timeout=15,
    )


# ---------------------------------------------------------------------------
# Test 1: ticket-revert.sh writes a REVERT event file with correct fields
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_ticket_revert_writes_revert_event(tmp_path: Path) -> None:
    """ticket revert <ticket_id> <target_uuid> --reason=<r> must write a REVERT
    event file in .tickets-tracker/<ticket_id>/ with the correct fields.

    Contract: revert-event.md
      - event_type == 'REVERT'
      - data.target_event_uuid == <target_uuid>
      - data.target_event_type == 'STATUS'
      - data.reason == 'test reason'
      - File named: <timestamp>-<uuid>-REVERT.json
    """
    ticket_id = "tkt-rev-001"
    tracker_dir = _setup_tracker(tmp_path, ticket_id)
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True)

    # Write CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742600000,
        uuid=_CREATE_UUID,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Test ticket", "parent_id": None},
    )

    # Write STATUS event — this is what we will target for revert
    _write_event(
        ticket_dir,
        timestamp=1742600100,
        uuid=_STATUS_UUID,
        event_type="STATUS",
        data={"status": "closed", "current_status": "open"},
    )

    result = _run_ticket_revert(
        tracker_dir, ticket_id, _STATUS_UUID, reason="test reason"
    )

    assert result.returncode == 0, (
        f"ticket revert must exit 0 on success; got {result.returncode}.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

    # Find the REVERT event file
    revert_files = sorted(ticket_dir.glob("*-REVERT.json"))
    assert len(revert_files) == 1, (
        f"Expected exactly 1 REVERT event file in {ticket_dir}, "
        f"found: {[f.name for f in revert_files]}"
    )

    event = json.loads(revert_files[0].read_text())

    assert event["event_type"] == "REVERT", (
        f"event_type must be 'REVERT', got: {event.get('event_type')!r}"
    )
    assert event["data"]["target_event_uuid"] == _STATUS_UUID, (
        f"data.target_event_uuid must be {_STATUS_UUID!r}, "
        f"got: {event['data'].get('target_event_uuid')!r}"
    )
    assert event["data"]["target_event_type"] == "STATUS", (
        f"data.target_event_type must be 'STATUS', "
        f"got: {event['data'].get('target_event_type')!r}"
    )
    assert event["data"]["reason"] == "test reason", (
        f"data.reason must be 'test reason', got: {event['data'].get('reason')!r}"
    )
    # Verify filename convention: <timestamp>-<uuid>-REVERT.json
    assert revert_files[0].name.endswith("-REVERT.json"), (
        f"REVERT event filename must end with '-REVERT.json', got: {revert_files[0].name!r}"
    )
    parts = revert_files[0].stem.split("-")
    # stem is e.g. "1742600200-<uuid-parts>-REVERT" so last part is REVERT
    assert parts[-1] == "REVERT", (
        f"filename stem must end with '-REVERT', got stem: {revert_files[0].stem!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: REVERT-of-REVERT is rejected by the CLI
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_ticket_revert_rejects_revert_of_revert(tmp_path: Path) -> None:
    """ticket revert must exit non-zero when the target event is itself a REVERT.

    Contract: revert-event.md (REVERT-of-REVERT Constraint)
      - Exit non-zero
      - stderr contains 'cannot revert a REVERT event'
    """
    ticket_id = "tkt-rev-002"
    tracker_dir = _setup_tracker(tmp_path, ticket_id)
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True)

    # Write CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742600000,
        uuid=_CREATE_UUID,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Test ticket", "parent_id": None},
    )

    # Write STATUS event (original action)
    _write_event(
        ticket_dir,
        timestamp=1742600100,
        uuid=_STATUS_UUID,
        event_type="STATUS",
        data={"status": "closed", "current_status": "open"},
    )

    # Write REVERT event (targeting the STATUS event) — this is the target we'll try to revert
    _write_event(
        ticket_dir,
        timestamp=1742600200,
        uuid=_REVERT_UUID,
        event_type="REVERT",
        data={
            "target_event_uuid": _STATUS_UUID,
            "target_event_type": "STATUS",
            "reason": "first revert",
        },
    )

    # Attempt to revert the REVERT event — must be rejected
    result = _run_ticket_revert(tracker_dir, ticket_id, _REVERT_UUID)

    assert result.returncode != 0, (
        f"ticket revert targeting a REVERT event must exit non-zero; "
        f"got returncode={result.returncode}.\nstdout: {result.stdout}"
    )
    assert (
        "cannot revert a REVERT event" in result.stderr.lower()
        or "cannot revert a revert" in result.stderr.lower()
    ), (
        f"stderr must contain 'cannot revert a REVERT event'; "
        f"got stderr: {result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: Nonexistent target UUID is rejected by the CLI
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_ticket_revert_rejects_nonexistent_target(tmp_path: Path) -> None:
    """ticket revert must exit non-zero when the target UUID does not exist.

    Contract: revert-event.md (field constraints)
      - Exit non-zero
      - stderr contains 'event not found' or 'no event with UUID'
    """
    ticket_id = "tkt-rev-003"
    tracker_dir = _setup_tracker(tmp_path, ticket_id)
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True)

    # Write CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742600000,
        uuid=_CREATE_UUID,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Test ticket", "parent_id": None},
    )

    nonexistent_uuid = "99999999-9999-4999-9999-999999999999"
    result = _run_ticket_revert(tracker_dir, ticket_id, nonexistent_uuid)

    assert result.returncode != 0, (
        f"ticket revert with nonexistent UUID must exit non-zero; "
        f"got returncode={result.returncode}.\nstdout: {result.stdout}"
    )
    stderr_lower = result.stderr.lower()
    assert "event not found" in stderr_lower or "no event with uuid" in stderr_lower, (
        f"stderr must contain 'event not found' or 'no event with UUID'; "
        f"got stderr: {result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# Test 4: Reducer records reverts in compiled state (reverts list)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
@pytest.mark.xfail(
    reason="RED: dso-zso6 — REVERT event handling in reducer not yet implemented"
)
def test_reducer_records_reverts_in_compiled_state(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """After reducing a ticket with CREATE + STATUS + REVERT events, the compiled
    state must have a 'reverts' list with one entry recording the REVERT.

    Contract: revert-event.md (Reducer Semantics)
      - state['reverts'] is a list with 1 entry
      - entry has 'target_event_uuid' == _STATUS_UUID
      - entry has 'target_event_type' == 'STATUS'
      - entry has 'uuid' == _REVERT_UUID
    """
    ticket_id = "tkt-rev-004"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir(parents=True)

    # Write CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742600000,
        uuid=_CREATE_UUID,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Reducer revert test", "parent_id": None},
    )

    # Write STATUS event (to be reverted)
    _write_event(
        ticket_dir,
        timestamp=1742600100,
        uuid=_STATUS_UUID,
        event_type="STATUS",
        data={"status": "closed", "current_status": "open"},
    )

    # Write REVERT event targeting STATUS
    _write_event(
        ticket_dir,
        timestamp=1742600200,
        uuid=_REVERT_UUID,
        event_type="REVERT",
        data={
            "target_event_uuid": _STATUS_UUID,
            "target_event_type": "STATUS",
            "reason": "reverted prematurely",
        },
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, (
        "reduce_ticket must return a dict for a ticket with CREATE event"
    )

    assert "reverts" in state, (
        f"compiled state must have a 'reverts' key; got keys: {list(state.keys())}"
    )
    assert isinstance(state["reverts"], list), (
        f"state['reverts'] must be a list; got: {type(state['reverts'])!r}"
    )
    assert len(state["reverts"]) == 1, (
        f"state['reverts'] must have 1 entry; got {len(state['reverts'])}: {state['reverts']}"
    )

    revert_entry = state["reverts"][0]
    assert revert_entry["target_event_uuid"] == _STATUS_UUID, (
        f"revert entry 'target_event_uuid' must be {_STATUS_UUID!r}; "
        f"got: {revert_entry.get('target_event_uuid')!r}"
    )
    assert revert_entry["target_event_type"] == "STATUS", (
        f"revert entry 'target_event_type' must be 'STATUS'; "
        f"got: {revert_entry.get('target_event_type')!r}"
    )
    assert revert_entry["uuid"] == _REVERT_UUID, (
        f"revert entry 'uuid' must be {_REVERT_UUID!r}; "
        f"got: {revert_entry.get('uuid')!r}"
    )


# ---------------------------------------------------------------------------
# Test 5: Reducer does NOT automatically undo status when REVERT targets STATUS
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
@pytest.mark.xfail(
    reason="RED: dso-zso6 — REVERT event handling in reducer not yet implemented"
)
def test_reducer_revert_does_not_undo_status_automatically(
    tmp_path: Path, reducer: ModuleType
) -> None:
    """After reducing CREATE + STATUS(closed) + REVERT(targeting STATUS), the
    compiled state must still show status='closed'. The reducer must NOT
    automatically undo the status — only bridge-outbound handles the outbound effect.

    Contract: revert-event.md (Reducer Semantics, point 2)
      - state['status'] == 'closed'  (NOT reverted to 'open')
      - state['reverts'] has 1 entry (REVERT is recorded)
    """
    ticket_id = "tkt-rev-005"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir(parents=True)

    # Write CREATE event
    _write_event(
        ticket_dir,
        timestamp=1742600000,
        uuid=_CREATE_UUID,
        event_type="CREATE",
        data={"ticket_type": "task", "title": "Status undo test", "parent_id": None},
    )

    # Write STATUS event — transition to closed
    _write_event(
        ticket_dir,
        timestamp=1742600100,
        uuid=_STATUS_UUID,
        event_type="STATUS",
        data={"status": "closed", "current_status": "open"},
    )

    # Write REVERT event targeting the STATUS (closed) event
    _write_event(
        ticket_dir,
        timestamp=1742600200,
        uuid=_REVERT_UUID,
        event_type="REVERT",
        data={
            "target_event_uuid": _STATUS_UUID,
            "target_event_type": "STATUS",
            "reason": "closed prematurely",
        },
    )

    state = reducer.reduce_ticket(ticket_dir)

    assert state is not None, (
        "reduce_ticket must return a dict for a ticket with CREATE event"
    )

    assert state["status"] == "closed", (
        f"state['status'] must remain 'closed' — the reducer must NOT automatically "
        f"undo the STATUS effect; got: {state.get('status')!r}. "
        "Only bridge-outbound handles outbound undo effects."
    )

    assert "reverts" in state, (
        f"compiled state must have a 'reverts' key; got keys: {list(state.keys())}"
    )
    assert len(state["reverts"]) == 1, (
        f"state['reverts'] must have 1 entry; got {len(state['reverts'])}: {state['reverts']}"
    )
