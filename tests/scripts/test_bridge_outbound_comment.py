"""RED tests for COMMENT event handling in bridge-outbound.py.

These tests are RED — they test COMMENT event functionality that does not yet exist
in bridge-outbound.py. All 5 test functions must FAIL before implementation.

Expected behavior to implement:
- process_outbound handles COMMENT events by calling acli_client.add_comment
- UUID marker is appended to comment body: <!-- origin-uuid: {event_uuid} -->
- COMMENT events are skipped if no SYNC event exists (no Jira mapping)
- COMMENT events are skipped if env_id matches bridge env ID (echo prevention)
- After successful add_comment, dedup map is written to .jira-comment-map
- COMMENT events are skipped if UUID is already in dedup map (idempotency)

Test: python3 -m pytest tests/scripts/test_bridge_outbound_comment.py
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
# Helpers — mirrored from test_bridge_outbound.py (not imported to keep tests
# independently runnable)
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_UUID1 = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_UUID2 = "aabbccdd-1122-3344-5566-778899aabbcc"
_UUID3 = "deadbeef-dead-beef-dead-beefdeadbeef"

_COMMENT_UUID = "cccc1111-cccc-4000-8000-cccccccccccc"
_JIRA_COMMENT_ID = "jira-comment-42"
_JIRA_KEY = "DSO-42"


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


def _write_sync_file(ticket_dir: Path, jira_key: str, uuid: str = _UUID2) -> Path:
    """Write a SYNC event file mapping this ticket to a Jira key."""
    sync_payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": ticket_dir.name,
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742605100,
        "run_id": "12345678901",
    }
    sync_file = ticket_dir / f"1742605100-{uuid}-SYNC.json"
    sync_file.write_text(json.dumps(sync_payload))
    return sync_file


# ---------------------------------------------------------------------------
# Test 1: COMMENT event pushes to Jira with UUID marker in body
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_outbound_push_comment_calls_add_comment_with_uuid_marker(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a COMMENT event in the git diff for a ticket with an existing SYNC
    (mapped to DSO-42), process_outbound calls acli_client.add_comment('DSO-42', body)
    where body ends with <!-- origin-uuid: {event_uuid} -->.
    """
    ticket_dir = tmp_path / "w21-with-sync"
    ticket_dir.mkdir()

    # Write SYNC file so ticket has a Jira mapping
    _write_sync_file(ticket_dir, jira_key=_JIRA_KEY)

    # Write a COMMENT event
    comment_body = "This is a test comment."
    comment_file = _write_event(
        ticket_dir,
        timestamp=1742605400,
        uuid=_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": comment_body},
        env_id=_OTHER_ENV_ID,
    )

    events = [
        {
            "ticket_id": "w21-with-sync",
            "event_type": "COMMENT",
            "file_path": str(comment_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.add_comment = MagicMock(return_value={"id": _JIRA_COMMENT_ID})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.add_comment.assert_called_once()
    call_args = mock_client.add_comment.call_args
    # First positional arg is the Jira key
    assert call_args[0][0] == _JIRA_KEY, (
        f"add_comment must be called with jira_key='{_JIRA_KEY}', got {call_args[0][0]!r}"
    )
    # Second arg is the comment body
    body_sent = call_args[0][1]
    expected_marker = f"<!-- origin-uuid: {_COMMENT_UUID} -->"
    assert body_sent.endswith(expected_marker), (
        f"Comment body must end with UUID marker '{expected_marker}', got: {body_sent!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: COMMENT event skipped when ticket has no SYNC (no Jira mapping)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_outbound_push_comment_skips_ticket_without_sync(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a COMMENT event for a ticket with NO SYNC event (no Jira mapping),
    process_outbound does NOT call acli_client.add_comment.

    RED verification: a second ticket WITH a SYNC must result in add_comment
    being called once (proving COMMENT handling exists), while the no-sync
    ticket adds zero calls. Without COMMENT handling, add_comment is never
    called at all, causing the assert_called_once() to fail RED.
    """
    # Ticket without sync
    ticket_no_sync = tmp_path / "w21-no-sync"
    ticket_no_sync.mkdir()

    comment_file_no_sync = _write_event(
        ticket_no_sync,
        timestamp=1742605400,
        uuid=_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": "A comment on an unsynced ticket."},
        env_id=_OTHER_ENV_ID,
    )

    # Ticket WITH sync (control — add_comment must be called for this one)
    ticket_with_sync = tmp_path / "w21-has-sync"
    ticket_with_sync.mkdir()
    _write_sync_file(ticket_with_sync, jira_key=_JIRA_KEY)

    _CONTROL_UUID = "eeee2222-eeee-4000-8000-eeeeeeeeeeee"
    comment_file_with_sync = _write_event(
        ticket_with_sync,
        timestamp=1742605401,
        uuid=_CONTROL_UUID,
        event_type="COMMENT",
        data={"body": "A comment on a synced ticket."},
        env_id=_OTHER_ENV_ID,
    )

    events = [
        {
            "ticket_id": "w21-no-sync",
            "event_type": "COMMENT",
            "file_path": str(comment_file_no_sync),
        },
        {
            "ticket_id": "w21-has-sync",
            "event_type": "COMMENT",
            "file_path": str(comment_file_with_sync),
        },
    ]

    mock_client = MagicMock()
    mock_client.add_comment = MagicMock(return_value={"id": _JIRA_COMMENT_ID})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # The synced ticket's comment must be pushed exactly once (RED if no COMMENT handling)
    mock_client.add_comment.assert_called_once()
    call_args = mock_client.add_comment.call_args
    assert call_args[0][0] == _JIRA_KEY, (
        "add_comment must be called only for the synced ticket"
    )


# ---------------------------------------------------------------------------
# Test 3: COMMENT event skipped when env_id matches bridge env ID (echo prevention)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_outbound_push_comment_skips_bridge_originated_comment(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a COMMENT event whose env_id matches the bridge env ID,
    process_outbound does NOT call acli_client.add_comment (echo prevention).

    RED verification: a second COMMENT event with a different env_id (user)
    must cause add_comment to be called once (proving COMMENT handling exists).
    Without COMMENT handling, add_comment is never called, so
    assert_called_once() fails RED.
    """
    # Ticket with SYNC — bridge-originated comment must be skipped
    ticket_bridge = tmp_path / "w21-bridge-comment"
    ticket_bridge.mkdir()
    _write_sync_file(ticket_bridge, jira_key=_JIRA_KEY)

    comment_bridge = _write_event(
        ticket_bridge,
        timestamp=1742605400,
        uuid=_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": "Bridge-originated comment that should be suppressed."},
        env_id=_BRIDGE_ENV_ID,  # same as bridge — must be filtered
    )

    # Ticket with SYNC — user-originated comment must go through
    ticket_user = tmp_path / "w21-user-comment"
    ticket_user.mkdir()
    _write_sync_file(ticket_user, jira_key="DSO-43", uuid=_UUID3)

    _USER_COMMENT_UUID = "ffff3333-ffff-4000-8000-ffffffffffff"
    comment_user = _write_event(
        ticket_user,
        timestamp=1742605401,
        uuid=_USER_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": "User comment that must be pushed."},
        env_id=_OTHER_ENV_ID,  # different env — must pass through
    )

    events = [
        {
            "ticket_id": "w21-bridge-comment",
            "event_type": "COMMENT",
            "file_path": str(comment_bridge),
        },
        {
            "ticket_id": "w21-user-comment",
            "event_type": "COMMENT",
            "file_path": str(comment_user),
        },
    ]

    mock_client = MagicMock()
    mock_client.add_comment = MagicMock(return_value={"id": _JIRA_COMMENT_ID})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # User comment must be pushed; bridge comment must be suppressed
    # Without COMMENT handling, this call_count == 0, failing RED
    mock_client.add_comment.assert_called_once()
    call_args = mock_client.add_comment.call_args
    assert call_args[0][0] == "DSO-43", (
        "add_comment must be called for the user-originated comment (DSO-43), not the bridge comment"
    )


# ---------------------------------------------------------------------------
# Test 4: Successful add_comment writes both sides of dedup map to .jira-comment-map
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_outbound_push_comment_writes_jira_id_to_dedup_map(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """After a successful add_comment call returning {id: 'jira-comment-42'},
    the dedup map file at .tickets-tracker/<ticket-id>/.jira-comment-map is
    written with:
      uuid_to_jira_id[event_uuid] = 'jira-comment-42'
      jira_id_to_uuid['jira-comment-42'] = event_uuid
    """
    ticket_dir = tmp_path / "w21-dedup-write"
    ticket_dir.mkdir()

    _write_sync_file(ticket_dir, jira_key=_JIRA_KEY)

    comment_file = _write_event(
        ticket_dir,
        timestamp=1742605400,
        uuid=_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": "Dedup map write test comment."},
        env_id=_OTHER_ENV_ID,
    )

    events = [
        {
            "ticket_id": "w21-dedup-write",
            "event_type": "COMMENT",
            "file_path": str(comment_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.add_comment = MagicMock(return_value={"id": _JIRA_COMMENT_ID})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    dedup_map_path = ticket_dir / ".jira-comment-map"
    assert dedup_map_path.exists(), (
        f"Dedup map file must be created at {dedup_map_path}"
    )

    dedup_data = json.loads(dedup_map_path.read_text())
    assert "uuid_to_jira_id" in dedup_data, "Dedup map must have 'uuid_to_jira_id' key"
    assert "jira_id_to_uuid" in dedup_data, "Dedup map must have 'jira_id_to_uuid' key"

    assert dedup_data["uuid_to_jira_id"].get(_COMMENT_UUID) == _JIRA_COMMENT_ID, (
        f"uuid_to_jira_id[{_COMMENT_UUID!r}] must equal {_JIRA_COMMENT_ID!r}"
    )
    assert dedup_data["jira_id_to_uuid"].get(_JIRA_COMMENT_ID) == _COMMENT_UUID, (
        f"jira_id_to_uuid[{_JIRA_COMMENT_ID!r}] must equal {_COMMENT_UUID!r}"
    )


# ---------------------------------------------------------------------------
# Test 5: Idempotency — add_comment not called if UUID already in dedup map
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_outbound_push_comment_does_not_duplicate_if_already_in_dedup_map(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """If the event UUID is already in uuid_to_jira_id, add_comment is NOT called
    again (idempotency guard).

    RED verification: a second COMMENT event with a NEW UUID (not in dedup map)
    must cause add_comment to be called once, while the already-mapped UUID is
    skipped. Without COMMENT handling, add_comment is never called, failing
    assert_called_once() RED.
    """
    # Ticket with a COMMENT event that was already pushed (UUID in dedup map)
    ticket_dup = tmp_path / "w21-idempotent-comment"
    ticket_dup.mkdir()
    _write_sync_file(ticket_dup, jira_key=_JIRA_KEY)

    comment_dup = _write_event(
        ticket_dup,
        timestamp=1742605400,
        uuid=_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": "Already-pushed comment."},
        env_id=_OTHER_ENV_ID,
    )

    # Pre-populate the dedup map to simulate a previous successful push
    dedup_map_path = ticket_dup / ".jira-comment-map"
    existing_dedup = {
        "uuid_to_jira_id": {_COMMENT_UUID: _JIRA_COMMENT_ID},
        "jira_id_to_uuid": {_JIRA_COMMENT_ID: _COMMENT_UUID},
    }
    dedup_map_path.write_text(json.dumps(existing_dedup))

    # A second ticket with a NEW UUID (not yet in dedup map) — must be pushed
    ticket_new = tmp_path / "w21-new-comment"
    ticket_new.mkdir()
    _write_sync_file(ticket_new, jira_key="DSO-99", uuid=_UUID3)

    _NEW_COMMENT_UUID = "aaaa4444-aaaa-4000-8000-aaaaaaaaaaaa"
    comment_new = _write_event(
        ticket_new,
        timestamp=1742605402,
        uuid=_NEW_COMMENT_UUID,
        event_type="COMMENT",
        data={"body": "A new, not-yet-pushed comment."},
        env_id=_OTHER_ENV_ID,
    )

    events = [
        {
            "ticket_id": "w21-idempotent-comment",
            "event_type": "COMMENT",
            "file_path": str(comment_dup),
        },
        {
            "ticket_id": "w21-new-comment",
            "event_type": "COMMENT",
            "file_path": str(comment_new),
        },
    ]

    mock_client = MagicMock()
    mock_client.add_comment = MagicMock(return_value={"id": "jira-comment-99"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Only the new comment must be pushed; duplicate must be skipped
    # Without COMMENT handling, call_count == 0, failing assert_called_once() RED
    mock_client.add_comment.assert_called_once()
    call_args = mock_client.add_comment.call_args
    assert call_args[0][0] == "DSO-99", (
        "add_comment must be called only for the new comment (DSO-99), not the already-pushed one"
    )
