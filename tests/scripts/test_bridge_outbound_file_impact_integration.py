"""RED integration tests for FILE_IMPACT outbound bridge path.

These tests are RED — they test the FILE_IMPACT event handling in bridge-outbound.py
which does not yet exist. All test functions MUST FAIL before implementation.

Tests verify the outbound bridge handles FILE_IMPACT events by:
  (a) Calling acli_client.set_issue_property(jira_key, "dso.file_impact", file_impact_list)
  (b) Dispatching credentials to AcliClient.set_issue_property (HTTP header injection
      is AcliClient's responsibility, unit-tested in implementation story C/D)
  (c) Posting a comment with a UUID marker for dedup, and suppressing duplicate posts
  (d) Emitting a BRIDGE_ALERT event with reason FILE_IMPACT_SYNC_FAILED on PUT failure

Tests use process_events() + temp .tickets-tracker + MagicMock acli_client.
Pattern matches tests/scripts/test_bridge_outbound_integration.py.
"""

from __future__ import annotations

import importlib.util
import json
import re
import time
import uuid
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
    if not SCRIPT_PATH.exists():
        pytest.fail(f"bridge-outbound.py not found at {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_JIRA_KEY = "DSO-42"
_TICKET_ID = "tkt-fi-test"

_FILE_IMPACT_LIST = [{"path": "src/foo.py", "reason": "modified"}]

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _write_event(
    ticket_dir: Path, event_type: str, data: dict, ts_offset: int = 0
) -> Path:
    ts = int(time.time()) + ts_offset
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-{event_type}.json"
    payload = {
        "event_type": event_type,
        "timestamp": ts,
        "uuid": event_uuid,
        "env_id": _OTHER_ENV_ID,
        "data": data,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def _write_sync(ticket_dir: Path) -> Path:
    ts = int(time.time()) - 1
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-SYNC.json"
    payload = {
        "event_type": "SYNC",
        "jira_key": _JIRA_KEY,
        "local_id": _TICKET_ID,
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": ts,
        "run_id": "test-run",
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return path


def _setup_ticket(tmp_path: Path) -> tuple[Path, Path]:
    """Create ticket dir with CREATE + SYNC events. Returns (tracker_dir, ticket_dir)."""
    tracker_dir = tmp_path / ".tickets-tracker"
    ticket_dir = tracker_dir / _TICKET_ID
    ticket_dir.mkdir(parents=True)
    _write_event(
        ticket_dir,
        "CREATE",
        {
            "title": "Test ticket",
            "ticket_type": "task",
            "author": "test",
            "priority": 2,
        },
        ts_offset=-10,
    )
    _write_sync(ticket_dir)
    return tracker_dir, ticket_dir


def _write_file_impact(ticket_dir: Path, file_impact: list | None = None) -> Path:
    """Write a FILE_IMPACT event to the ticket dir."""
    if file_impact is None:
        file_impact = _FILE_IMPACT_LIST
    return _write_event(ticket_dir, "FILE_IMPACT", {"file_impact": file_impact})


def _make_mock_acli() -> MagicMock:
    mock = MagicMock()
    mock.create_issue = MagicMock(return_value={"key": _JIRA_KEY})
    mock.update_issue = MagicMock(return_value={"key": _JIRA_KEY})
    mock.get_issue = MagicMock(return_value={"key": _JIRA_KEY})
    return mock


# ---------------------------------------------------------------------------
# Tests (all fail RED — no FILE_IMPACT branch in process_outbound dispatcher)
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_file_impact_puts_to_property_endpoint(
    bridge: ModuleType, tmp_path: Path
) -> None:
    """(DD3a) process_events dispatches FILE_IMPACT to acli_client.set_issue_property
    with the correct jira_key, property key 'dso.file_impact', and file impact list."""
    tracker_dir, ticket_dir = _setup_ticket(tmp_path)
    _write_file_impact(ticket_dir)
    mock_acli = _make_mock_acli()

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_acli.set_issue_property.assert_called_once_with(
        _JIRA_KEY, "dso.file_impact", _FILE_IMPACT_LIST
    )


@pytest.mark.integration
@pytest.mark.scripts
def test_file_impact_credentials_passed_to_client(
    bridge: ModuleType, tmp_path: Path
) -> None:
    """(DD3b) process_events calls acli_client.set_issue_property, confirming the
    dispatcher routes FILE_IMPACT to the credentials-bearing client method.

    Note: HTTP Authorization header injection is AcliClient.set_issue_property's
    implementation concern (unit-tested in AcliClient tests in story C/D, not here).
    This test verifies the dispatcher invokes the method — credential transport follows.
    """
    tracker_dir, ticket_dir = _setup_ticket(tmp_path)
    _write_file_impact(ticket_dir)
    mock_acli = _make_mock_acli()

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_acli.set_issue_property.assert_called_once()


@pytest.mark.integration
@pytest.mark.scripts
def test_file_impact_posts_uuid_marker_comment(
    bridge: ModuleType, tmp_path: Path
) -> None:
    """(DD3c) process_events posts a comment with a UUID marker for dedup, and
    replaying the exact same events does NOT trigger a second comment (call_count==1).

    Dedup is keyed on the UUID embedded in the comment body — replaying the same
    FILE_IMPACT event file (same UUID) a second time must not double-post.
    """
    tracker_dir, ticket_dir = _setup_ticket(tmp_path)
    _write_file_impact(ticket_dir)
    mock_acli = _make_mock_acli()

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_acli.add_comment.called, (
        "Expected add_comment to be called with UUID marker"
    )
    body = mock_acli.add_comment.call_args.args[1]
    assert re.search(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", body
    ), f"Expected UUID marker in comment body, got: {body!r}"

    # Dedup: replaying the same events (no new FILE_IMPACT written) must NOT produce
    # a second comment. The implementation must key dedup on the event UUID in the
    # comment body so identical events are idempotent.
    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )
    assert mock_acli.add_comment.call_count == 1, (
        f"Expected dedup to suppress repeated comment, got call_count={mock_acli.add_comment.call_count}"
    )


@pytest.mark.integration
@pytest.mark.scripts
def test_file_impact_emits_bridge_alert_on_put_failure(
    bridge: ModuleType, tmp_path: Path
) -> None:
    """(DD3d) When set_issue_property raises, a BRIDGE_ALERT event is written to the
    ticket directory with reason FILE_IMPACT_SYNC_FAILED."""
    tracker_dir, ticket_dir = _setup_ticket(tmp_path)
    _write_file_impact(ticket_dir)
    mock_acli = _make_mock_acli()
    mock_acli.set_issue_property.side_effect = Exception("Jira PUT failed: 503")

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    alert_files = [
        f for f in ticket_dir.iterdir() if f.name.endswith("-BRIDGE_ALERT.json")
    ]
    assert alert_files, (
        "Expected a BRIDGE_ALERT event file in ticket dir after PUT failure, found none"
    )
    alert = json.loads(alert_files[0].read_text(encoding="utf-8"))
    assert alert["data"]["reason"] == "FILE_IMPACT_SYNC_FAILED", (
        f"Expected reason FILE_IMPACT_SYNC_FAILED, got {alert['data']['reason']!r}"
    )


@pytest.mark.integration
@pytest.mark.scripts
def test_file_impact_put_failure_still_attempts_comment_add(
    bridge: ModuleType, tmp_path: Path
) -> None:
    """When set_issue_property raises, add_comment is still called (no early return).

    RED: current code does `return []` after BRIDGE_ALERT on PUT failure,
    which short-circuits the comment add entirely.
    """
    tracker_dir, ticket_dir = _setup_ticket(tmp_path)
    _write_file_impact(ticket_dir)
    mock_acli = _make_mock_acli()
    mock_acli.set_issue_property.side_effect = Exception("Jira PUT failed: 503")

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_acli.add_comment.called, (
        "Expected add_comment to be called even when set_issue_property raises, "
        "but it was never called (early return after PUT failure)"
    )


@pytest.mark.integration
@pytest.mark.scripts
def test_file_impact_comment_add_failure_emits_bridge_alert_comment_sync_failed(
    bridge: ModuleType, tmp_path: Path
) -> None:
    """When add_comment raises, BRIDGE_ALERT is written with reason FILE_IMPACT_COMMENT_SYNC_FAILED.

    RED: current code does not catch add_comment failures at all — the exception is
    silently swallowed and no BRIDGE_ALERT is emitted.
    """
    tracker_dir, ticket_dir = _setup_ticket(tmp_path)
    _write_file_impact(ticket_dir)
    mock_acli = _make_mock_acli()
    mock_acli.add_comment.side_effect = Exception("Jira comment failed: 503")

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    alert_files = [
        f for f in ticket_dir.iterdir() if f.name.endswith("-BRIDGE_ALERT.json")
    ]
    assert alert_files, (
        "Expected a BRIDGE_ALERT event file in ticket dir after comment add failure, found none"
    )
    reasons = [
        json.loads(f.read_text(encoding="utf-8"))["data"]["reason"] for f in alert_files
    ]
    assert "FILE_IMPACT_COMMENT_SYNC_FAILED" in reasons, (
        f"Expected reason FILE_IMPACT_COMMENT_SYNC_FAILED in BRIDGE_ALERT files, got reasons: {reasons!r}"
    )
