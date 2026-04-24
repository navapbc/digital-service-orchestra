"""Integration tests for bridge-inbound.py process_inbound() pipeline.

Fixture-based end-to-end tests that exercise process_inbound() with a
temporary .tickets-tracker directory and mocked ACLI client. No live
Jira or ACLI subprocess calls are made.

Validates:
- End-to-end: ACLI returns issues -> process_inbound creates events + checkpoint
- Idempotent: second run creates no new events (SYNC-based dedup)
- BRIDGE_ALERT: unmapped type triggers alert event
- Auth failure: 401 -> fast abort, checkpoint preserved
- Pagination: multiple pages of results all processed

Integration exemption: NOT RED-first -- written after implementation per
Integration Test Task Rule (external boundary: filesystem + mocked ACLI subprocess).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading -- filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-inbound.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_inbound", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def bridge() -> ModuleType:
    """Return the bridge-inbound module."""
    if not SCRIPT_PATH.exists():
        pytest.fail(f"bridge-inbound.py not found at {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "cccccccc-0000-4000-8000-000000000003"
_RUN_ID = "1234567890"
_LAST_PULL_TS = "2026-03-20T00:00:00Z"

_STATUS_MAPPING = {
    "To Do": "open",
    "In Progress": "in_progress",
    "Done": "closed",
}

_TYPE_MAPPING = {
    "Task": "task",
    "Story": "story",
    "Bug": "bug",
}


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _make_jira_issue(
    key: str,
    *,
    summary: str = "Test issue",
    status: str = "To Do",
    issue_type: str = "Task",
    updated: str = "2026-03-21T10:00:00.000+0000",
) -> dict:
    """Build a Jira issue dict matching the shape returned by ACLI search_issues."""
    return {
        "key": key,
        "fields": {
            "summary": summary,
            "status": {"name": status},
            "issuetype": {"name": issue_type},
            "created": "2026-03-20T08:00:00.000+0000",
            "updated": updated,
            "resolutiondate": None,
        },
    }


def _make_mock_acli(
    issues: list[dict] | None = None,
    *,
    timezone: str = "UTC",
) -> MagicMock:
    """Create a mock ACLI client with search_issues and get_myself."""
    mock = MagicMock()
    mock.get_myself.return_value = {"timeZone": timezone}

    if issues is not None:
        mock.search_issues.return_value = issues
    else:
        mock.search_issues.return_value = []

    return mock


def _make_config(
    checkpoint_file: str = "",
    *,
    status_mapping: dict | None = None,
    type_mapping: dict | None = None,
) -> dict:
    """Build a config dict for process_inbound()."""
    return {
        "bridge_env_id": _BRIDGE_ENV_ID,
        "overlap_buffer_minutes": 15,
        "checkpoint_file": checkpoint_file,
        "status_mapping": status_mapping
        if status_mapping is not None
        else _STATUS_MAPPING,
        "type_mapping": type_mapping if type_mapping is not None else _TYPE_MAPPING,
        "run_id": _RUN_ID,
    }


def _count_event_files(tracker_dir: Path, pattern: str) -> int:
    """Count event files matching a glob pattern recursively."""
    return len(list(tracker_dir.rglob(pattern)))


# ---------------------------------------------------------------------------
# Test: End-to-end — ACLI returns issues, process_inbound creates events
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_creates_events_for_new_jira_issues(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """process_inbound() creates CREATE event files for new Jira issues
    and updates the checkpoint file on success.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    checkpoint_file.write_text(json.dumps({"last_pull_ts": _LAST_PULL_TS}))

    issues = [
        _make_jira_issue("DSO-1", summary="First issue"),
        _make_jira_issue("DSO-2", summary="Second issue"),
    ]
    mock_acli = _make_mock_acli(issues)
    config = _make_config(str(checkpoint_file))

    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )

    # 2 CREATE event files should exist
    create_count = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count == 2, f"Expected 2 CREATE events, got {create_count}"

    # Each ticket directory should exist
    assert (tracker_dir / "jira-dso-1").is_dir()
    assert (tracker_dir / "jira-dso-2").is_dir()

    # Checkpoint should be updated (new timestamp > old)
    updated_checkpoint = json.loads(checkpoint_file.read_text())
    assert updated_checkpoint["last_pull_ts"] != _LAST_PULL_TS
    assert updated_checkpoint["last_run_id"] == _RUN_ID

    # ACLI should have been called
    mock_acli.search_issues.assert_called_once()
    mock_acli.get_myself.assert_called()


# ---------------------------------------------------------------------------
# Test: Idempotency — second run creates no additional CREATE events
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_idempotent_on_second_run(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Running process_inbound() twice with the same issues produces CREATE
    events only on the first run. The second run detects existing SYNC files
    (written by write_create_events idempotency guard) and skips.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    checkpoint_file.write_text(json.dumps({"last_pull_ts": _LAST_PULL_TS}))

    issues = [_make_jira_issue("DSO-10", summary="Idem issue")]
    mock_acli = _make_mock_acli(issues)
    config = _make_config(str(checkpoint_file))

    # First run — creates 1 CREATE event
    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )
    create_count_1 = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count_1 == 1, f"First run: expected 1 CREATE, got {create_count_1}"

    # Write a SYNC event to simulate outbound sync having acknowledged this ticket.
    # The idempotency guard in write_create_events checks for SYNC events.
    ticket_dir = tracker_dir / "jira-dso-10"
    sync_payload = {
        "event_type": "SYNC",
        "jira_key": "DSO-10",
        "local_id": "jira-dso-10",
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742605200,
        "run_id": _RUN_ID,
    }
    sync_file = ticket_dir / "1742605200-deadbeef-0000-4000-8000-000000000001-SYNC.json"
    sync_file.write_text(json.dumps(sync_payload))

    # Second run — should NOT create additional CREATE events
    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )
    create_count_2 = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count_2 == 1, (
        f"Second run: CREATE count should remain 1 (idempotent), got {create_count_2}"
    )


# ---------------------------------------------------------------------------
# Test: BRIDGE_ALERT for unmapped type
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_writes_bridge_alert_for_unmapped_type(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """A Jira issue with type 'Custom' not in type_mapping triggers a
    BRIDGE_ALERT event alongside the CREATE event.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    checkpoint_file.write_text(json.dumps({"last_pull_ts": _LAST_PULL_TS}))

    issues = [
        _make_jira_issue("DSO-20", summary="Custom type issue", issue_type="Custom"),
    ]
    mock_acli = _make_mock_acli(issues)
    config = _make_config(str(checkpoint_file))

    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )

    # CREATE event must NOT exist — unmapped types are skipped (2b6a-0a37)
    create_count = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count == 0, (
        f"Expected 0 CREATE events for unmapped type, got {create_count}"
    )

    # BRIDGE_ALERT event should exist
    alert_count = _count_event_files(tracker_dir, "*-BRIDGE_ALERT.json")
    assert alert_count == 1, f"Expected 1 BRIDGE_ALERT event, got {alert_count}"

    # Verify alert content
    alert_files = list(tracker_dir.rglob("*-BRIDGE_ALERT.json"))
    alert_data = json.loads(alert_files[0].read_text())
    assert alert_data["event_type"] == "BRIDGE_ALERT"
    assert (
        "unmapped type" in alert_data["reason"].lower()
        or "type" in alert_data["reason"].lower()
    )
    assert alert_data["env_id"] == _BRIDGE_ENV_ID


# ---------------------------------------------------------------------------
# Test: Unmapped type — no CREATE event should be written (bug 2b6a-0a37)
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_does_not_create_event_for_unmapped_type(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """A Jira issue with an unmapped type should NOT produce a CREATE event (2b6a-0a37).

    When process_inbound encounters an issue whose issuetype has no mapping in
    type_mapping, it writes a BRIDGE_ALERT but must NOT also write a CREATE event.
    Creating a local ticket for an issue we cannot classify causes undefined
    behavior downstream (ticket-reducer treats it as type 'None').
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    checkpoint_file.write_text(json.dumps({"last_pull_ts": _LAST_PULL_TS}))

    issues = [
        _make_jira_issue("DSO-99", summary="Unknown type issue", issue_type="Custom"),
    ]
    mock_acli = _make_mock_acli(issues)
    config = _make_config(str(checkpoint_file))

    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )

    # BRIDGE_ALERT must still be written
    alert_count = _count_event_files(tracker_dir, "*-BRIDGE_ALERT.json")
    assert alert_count == 1, (
        f"Expected 1 BRIDGE_ALERT for unmapped type, got {alert_count}"
    )

    # CREATE event must NOT be written — unmapped type cannot be locally classified
    create_count = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count == 0, (
        f"OUTBOUND inbound must NOT write a CREATE event for unmapped issue types (2b6a-0a37). "
        f"Got {create_count} CREATE event(s)."
    )


# ---------------------------------------------------------------------------
# Test: Auth failure — 401 aborts without updating checkpoint
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_does_not_update_checkpoint_on_auth_failure(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When search_issues raises CalledProcessError(returncode=401),
    process_inbound aborts and the checkpoint file is NOT updated.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    original_checkpoint = {"last_pull_ts": _LAST_PULL_TS}
    checkpoint_file.write_text(json.dumps(original_checkpoint))

    mock_acli = MagicMock()
    mock_acli.get_myself.return_value = {"timeZone": "UTC"}
    mock_acli.search_issues.side_effect = subprocess.CalledProcessError(
        returncode=401,
        cmd=["acli", "--action", "searchIssues"],
        output="Unauthorized",
    )

    config = _make_config(str(checkpoint_file))

    with pytest.raises(subprocess.CalledProcessError) as exc_info:
        bridge.process_inbound(
            tickets_root=tracker_dir,
            acli_client=mock_acli,
            last_pull_ts=_LAST_PULL_TS,
            config=config,
        )

    assert exc_info.value.returncode == 401

    # Checkpoint must be unchanged
    preserved_checkpoint = json.loads(checkpoint_file.read_text())
    assert preserved_checkpoint == original_checkpoint

    # No CREATE events should exist
    create_count = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count == 0


# ---------------------------------------------------------------------------
# Test: Pagination — 100+ issues across multiple pages
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_paginates_100_plus_issues(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """When ACLI returns 100 issues on page 0, 23 on page 1, and 0 on page 2,
    process_inbound creates 123 CREATE event files.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    checkpoint_file.write_text(json.dumps({"last_pull_ts": _LAST_PULL_TS}))

    # Build 123 unique issues
    page_0 = [_make_jira_issue(f"DSO-{i}") for i in range(1, 101)]
    page_1 = [_make_jira_issue(f"DSO-{i}") for i in range(101, 124)]

    mock_acli = MagicMock()
    mock_acli.get_myself.return_value = {"timeZone": "UTC"}

    # search_issues returns paginated results:
    # page 0 (start_at=0): 100 issues
    # page 1 (start_at=100): 23 issues (< 100 so pagination stops)
    mock_acli.search_issues.side_effect = [page_0, page_1]

    config = _make_config(str(checkpoint_file))

    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )

    # 123 CREATE event files should exist
    create_count = _count_event_files(tracker_dir, "*-CREATE.json")
    assert create_count == 123, f"Expected 123 CREATE events, got {create_count}"

    # 123 ticket directories should exist
    ticket_dirs = [d for d in tracker_dir.iterdir() if d.is_dir()]
    assert len(ticket_dirs) == 123, f"Expected 123 ticket dirs, got {len(ticket_dirs)}"

    # search_issues should have been called twice (page 0 and page 1)
    assert mock_acli.search_issues.call_count == 2

    # Checkpoint should be updated
    updated_checkpoint = json.loads(checkpoint_file.read_text())
    assert updated_checkpoint["last_pull_ts"] != _LAST_PULL_TS


# ---------------------------------------------------------------------------
# Test: Inbound round-trip — Jira "Relates" link → local relates_to LINK event
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_inbound_round_trip_jira_relates_link_creates_local_relates_to(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Inbound sync of a Jira 'Relates' link creates a local relates_to LINK event.

    Given: Two local ticket directories (jira-proj-1, jira-proj-2) each with a
        SYNC event referencing their Jira keys (PROJ-1, PROJ-2), so the idempotency
        guard does not attempt to re-create them.
    When: Jira API returns PROJ-1 with an issuelinks payload containing a
        'Relates' link to PROJ-2.
    Then: A local LINK event with relation='relates_to' is written into the
        jira-proj-1 ticket directory, linking jira-proj-1 → jira-proj-2.

    This is a RED test: bridge-inbound.py currently calls set_relationship()
    to push the link back to Jira (outbound) but does NOT write a local LINK
    event, so this test is expected to FAIL until the inbound link handler
    is implemented.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()

    checkpoint_file = tmp_path / "checkpoint.json"
    checkpoint_file.write_text(json.dumps({"last_pull_ts": _LAST_PULL_TS}))

    # --- Setup: create local ticket dirs with SYNC events ---
    # These SYNC events make the idempotency guard skip CREATE for both tickets.
    for jira_key, local_id in [("PROJ-1", "jira-proj-1"), ("PROJ-2", "jira-proj-2")]:
        ticket_dir = tracker_dir / local_id
        ticket_dir.mkdir()
        sync_payload = {
            "event_type": "SYNC",
            "jira_key": jira_key,
            "local_id": local_id,
            "env_id": _BRIDGE_ENV_ID,
            "timestamp": 1742605200,
            "run_id": _RUN_ID,
        }
        sync_file = (
            ticket_dir
            / f"1742605200-deadbeef-0000-4000-8000-{local_id.replace('-', '')[:12].ljust(12, '0')}-SYNC.json"
        )
        sync_file.write_text(json.dumps(sync_payload))

    # --- Build Jira issue for PROJ-1 with a 'Relates' issuelink to PROJ-2 ---
    issue_with_relates_link = {
        "key": "PROJ-1",
        "fields": {
            "summary": "First issue with relates link",
            "status": {"name": "To Do"},
            "issuetype": {"name": "Task"},
            "created": "2026-03-20T08:00:00.000+0000",
            "updated": "2026-03-21T10:00:00.000+0000",
            "resolutiondate": None,
            "issuelinks": [
                {
                    "type": {
                        "name": "Relates",
                        "inward": "relates to",
                        "outward": "relates to",
                    },
                    "outwardIssue": {
                        "key": "PROJ-2",
                        "fields": {"summary": "Second issue"},
                    },
                }
            ],
        },
    }

    mock_acli = _make_mock_acli([issue_with_relates_link])
    # set_relationship is available on the mock (MagicMock auto-creates it)
    config = _make_config(str(checkpoint_file))

    bridge.process_inbound(
        tickets_root=tracker_dir,
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
    )

    # --- Assert: a local LINK event with relation='relates_to' must exist ---
    # The inbound bridge must write a LINK event in jira-proj-1's directory
    # that records a relates_to relationship pointing to jira-proj-2.
    proj1_dir = tracker_dir / "jira-proj-1"
    link_files = list(proj1_dir.glob("*-LINK.json"))
    assert len(link_files) == 1, (
        f"Expected exactly 1 LINK event in jira-proj-1/ after inbound sync of a Jira 'Relates' "
        f"link, but found {len(link_files)}. bridge-inbound.py must write a local LINK event "
        "for inbound Jira links (not just call set_relationship outbound)."
    )

    # Verify the LINK event content
    link_data = json.loads(link_files[0].read_text())
    assert link_data.get("event_type") == "LINK", (
        f"Expected event_type='LINK', got {link_data.get('event_type')!r}"
    )
    assert link_data.get("data", {}).get("relation") == "relates_to", (
        f"Expected relation='relates_to', got {link_data.get('data', {}).get('relation')!r}"
    )
    assert link_data.get("data", {}).get("target_id") == "jira-proj-2", (
        f"Expected target_id='jira-proj-2', got {link_data.get('data', {}).get('target_id')!r}"
    )


# ---------------------------------------------------------------------------
# Test: non-UTC service account timezone — process_inbound must not abort
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_process_inbound_proceeds_when_service_account_timezone_is_not_utc(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """process_inbound() must NOT raise when the service account timezone is non-UTC.

    The fetch_jira_changes() TZ conversion handles non-UTC accounts automatically.
    The old abort guard was removed; this test verifies the behavior change is stable.

    Given: mock ACLI client returns timezone "America/Los_Angeles" (PDT, non-UTC)
    When:  process_inbound() is called
    Then:  no RuntimeError is raised and events are written for returned issues
    """
    issues = [_make_jira_issue("PROJ-1")]
    mock_acli = _make_mock_acli(issues, timezone="America/Los_Angeles")

    tracker = tmp_path / ".tickets-tracker"
    config = _make_config(checkpoint_file=str(tmp_path / "checkpoint.json"))

    # Must not raise RuntimeError or any other exception
    bridge.process_inbound(
        acli_client=mock_acli,
        last_pull_ts=_LAST_PULL_TS,
        config=config,
        tickets_root=tracker,
    )

    create_files = list(tracker.rglob("*-CREATE.json"))
    assert len(create_files) == 1, (
        f"Expected 1 CREATE event for PROJ-1 with PDT service account; "
        f"got {len(create_files)}. Abort guard may have been re-introduced."
    )
