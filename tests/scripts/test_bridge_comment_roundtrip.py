"""RED tests for comment round-trip dedup (outbound → inbound without duplication).

These tests are RED — they test functionality in bridge-inbound.py which does not
yet exist. All test functions must FAIL before bridge-inbound.py is implemented.

Scenario:
  A local COMMENT event is pushed outbound to Jira (bridge-outbound.py).
  The dedup map (.jira-comment-map) is pre-populated as if outbound ran and
  received Jira comment ID 'j-100'. When the inbound bridge then calls
  pull_comments, it must NOT write a new local COMMENT event for 'j-100'
  because that Jira comment originated locally (echo prevention).

Contract reference: plugins/dso/docs/contracts/comment-sync-dedup.md

Dedup state file path: .tickets-tracker/<ticket-id>/.jira-comment-map
Format:
  {
    "uuid_to_jira_id": {"<event_uuid>": "<jira_comment_id>"},
    "jira_id_to_uuid": {"<jira_comment_id>": "<event_uuid>"}
  }

The inbound bridge exposes:
    pull_comments(ticket_id, jira_key, tickets_root, acli_client) -> list[dict]
        Pull comments from Jira for the given ticket, writing new local COMMENT
        events only for comments not present in the dedup map. Returns list of
        newly written COMMENT event dicts.

Mock acli_client interface (inbound):
    acli_client.get_comments(jira_key) -> list[dict]
        Returns list of comment dicts: [{id: str, body: str}, ...]

Test: python3 -m pytest tests/scripts/test_bridge_comment_roundtrip.py
All tests must return non-zero until bridge-inbound.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
import time
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-inbound.py"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_EVENT_UUID = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_JIRA_COMMENT_ID = "j-100"
_TICKET_ID = "w21-rt1"
_JIRA_KEY = "DSO-42"

_COMMENT_BODY = "This comment was written locally and pushed to Jira."
_COMMENT_BODY_WITH_MARKER = f"{_COMMENT_BODY}\n<!-- origin-uuid: {_EVENT_UUID} -->"
_COMMENT_BODY_WITHOUT_MARKER = _COMMENT_BODY  # marker stripped by Jira editor


# ---------------------------------------------------------------------------
# Module fixture
# ---------------------------------------------------------------------------


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_inbound", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def bridge_inbound() -> ModuleType:
    """Return the bridge-inbound module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"bridge-inbound.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_comment_event(
    ticket_dir: Path,
    event_uuid: str = _EVENT_UUID,
    body: str = _COMMENT_BODY_WITH_MARKER,
    env_id: str = _OTHER_ENV_ID,
    ts: int | None = None,
) -> Path:
    """Write a well-formed COMMENT event JSON file and return its path."""
    if ts is None:
        ts = int(time.time()) - 100
    filename = f"{ts}-{event_uuid}-COMMENT.json"
    payload = {
        "event_type": "COMMENT",
        "uuid": event_uuid,
        "timestamp": ts,
        "author": "test-user",
        "env_id": env_id,
        "data": {"body": body},
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _write_sync_event(
    ticket_dir: Path,
    jira_key: str = _JIRA_KEY,
    local_id: str = _TICKET_ID,
    env_id: str = _BRIDGE_ENV_ID,
    ts: int | None = None,
) -> Path:
    """Write a SYNC event JSON file and return its path."""
    if ts is None:
        ts = int(time.time()) - 200
    sync_uuid = "cccccccc-0000-4000-8000-000000000003"
    filename = f"{ts}-{sync_uuid}-SYNC.json"
    payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": local_id,
        "env_id": env_id,
        "timestamp": ts,
        "run_id": "9876543210",
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _write_dedup_map(
    ticket_dir: Path,
    event_uuid: str = _EVENT_UUID,
    jira_comment_id: str = _JIRA_COMMENT_ID,
) -> Path:
    """Write a .jira-comment-map pre-populated as if outbound ran successfully."""
    dedup_map = {
        "uuid_to_jira_id": {event_uuid: jira_comment_id},
        "jira_id_to_uuid": {jira_comment_id: event_uuid},
    }
    path = ticket_dir / ".jira-comment-map"
    path.write_text(json.dumps(dedup_map))
    return path


def _count_comment_files(ticket_dir: Path) -> int:
    """Count COMMENT event files in the ticket directory."""
    return len(list(ticket_dir.glob("*-COMMENT.json")))


def _make_mock_acli(
    jira_comment_id: str = _JIRA_COMMENT_ID,
    comment_body: str = _COMMENT_BODY_WITH_MARKER,
) -> MagicMock:
    """Create a mock ACLI client whose get_comments returns one comment."""
    mock = MagicMock()
    mock.get_comments = MagicMock(
        return_value=[{"id": jira_comment_id, "body": comment_body}]
    )
    mock.add_comment = MagicMock(return_value={"id": jira_comment_id})
    return mock


# ---------------------------------------------------------------------------
# Test 1: round-trip with marker present — inbound must NOT re-import
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_comment_round_trip_no_duplication(
    tmp_path: Path, bridge_inbound: ModuleType
) -> None:
    """A comment pushed outbound and pulled inbound must NOT be re-imported.

    Scenario:
      1. Local COMMENT event exists for ticket 'w21-rt1' (mapped to 'DSO-42').
      2. Outbound bridge ran: dedup map pre-populated with
         uuid_to_jira_id[event_uuid] = 'j-100' and jira_id_to_uuid['j-100'] = event_uuid.
      3. Inbound bridge runs: get_comments('DSO-42') returns
         [{id: 'j-100', body: body_with_marker}].
      4. pull_comments must NOT write a new COMMENT event (dedup by jira_id 'j-100').

    Assert: ticket directory still contains exactly 1 COMMENT event file (the original).
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    ticket_dir = tracker_dir / _TICKET_ID
    ticket_dir.mkdir()

    # Step 1: write the original local COMMENT event
    _write_comment_event(
        ticket_dir,
        event_uuid=_EVENT_UUID,
        body=_COMMENT_BODY_WITH_MARKER,
        env_id=_OTHER_ENV_ID,
    )
    # Write SYNC event so the inbound bridge can find the jira_key mapping
    _write_sync_event(ticket_dir, jira_key=_JIRA_KEY, local_id=_TICKET_ID)

    # Step 2: dedup map pre-populated as if outbound ran and got 'j-100'
    _write_dedup_map(
        ticket_dir, event_uuid=_EVENT_UUID, jira_comment_id=_JIRA_COMMENT_ID
    )

    # Confirm setup: exactly 1 COMMENT file before inbound run
    assert _count_comment_files(ticket_dir) == 1, (
        "Setup: expected exactly 1 COMMENT event file before inbound run"
    )

    # Step 3: inbound bridge runs; Jira returns the comment with marker intact
    mock_acli = _make_mock_acli(
        jira_comment_id=_JIRA_COMMENT_ID,
        comment_body=_COMMENT_BODY_WITH_MARKER,
    )
    bridge_inbound.pull_comments(
        ticket_id=_TICKET_ID,
        jira_key=_JIRA_KEY,
        tickets_root=tracker_dir,
        acli_client=mock_acli,
    )

    # Step 4: assert no new COMMENT file was written
    comment_count = _count_comment_files(ticket_dir)
    assert comment_count == 1, (
        f"Inbound bridge must NOT re-import comment already in dedup map; "
        f"found {comment_count} COMMENT files (expected 1)."
    )


# ---------------------------------------------------------------------------
# Test 2: round-trip with marker stripped — inbound must still NOT re-import
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_comment_round_trip_stripped_marker_no_duplication(
    tmp_path: Path, bridge_inbound: ModuleType
) -> None:
    """Inbound still skips the comment when the origin marker is stripped.

    Scenario:
      Same as test_comment_round_trip_no_duplication, but get_comments returns
      [{id: 'j-100', body: body_WITHOUT_marker}] because a Jira editor stripped
      the HTML comment. The Jira comment ID 'j-100' is the PRIMARY dedup key
      and must survive marker stripping.

    Assert: ticket directory still contains exactly 1 COMMENT event file.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    ticket_dir = tracker_dir / _TICKET_ID
    ticket_dir.mkdir()

    # Step 1: write the original local COMMENT event (body with marker locally)
    _write_comment_event(
        ticket_dir,
        event_uuid=_EVENT_UUID,
        body=_COMMENT_BODY_WITH_MARKER,
        env_id=_OTHER_ENV_ID,
    )
    # Write SYNC event so the inbound bridge can find the jira_key mapping
    _write_sync_event(ticket_dir, jira_key=_JIRA_KEY, local_id=_TICKET_ID)

    # Step 2: dedup map pre-populated as if outbound ran and got 'j-100'
    _write_dedup_map(
        ticket_dir, event_uuid=_EVENT_UUID, jira_comment_id=_JIRA_COMMENT_ID
    )

    # Confirm setup: exactly 1 COMMENT file before inbound run
    assert _count_comment_files(ticket_dir) == 1, (
        "Setup: expected exactly 1 COMMENT event file before inbound run"
    )

    # Step 3: inbound bridge runs; Jira returns the comment WITHOUT the marker
    # (simulating a Jira rich-text editor stripping the HTML comment)
    mock_acli = _make_mock_acli(
        jira_comment_id=_JIRA_COMMENT_ID,
        comment_body=_COMMENT_BODY_WITHOUT_MARKER,
    )
    bridge_inbound.pull_comments(
        ticket_id=_TICKET_ID,
        jira_key=_JIRA_KEY,
        tickets_root=tracker_dir,
        acli_client=mock_acli,
    )

    # Step 4: assert no new COMMENT file was written (dedup by jira_id, not marker)
    comment_count = _count_comment_files(ticket_dir)
    assert comment_count == 1, (
        f"Inbound bridge must NOT re-import comment when Jira comment ID 'j-100' is in "
        f"dedup map, even if the origin marker was stripped; "
        f"found {comment_count} COMMENT files (expected 1)."
    )
