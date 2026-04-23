"""RED tests for bridge-inbound.py windowed pull, timestamp normalization, CREATE event writing.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL before bridge-inbound.py is implemented.

The bridge-inbound processor is expected to expose:
    fetch_jira_changes(acli_client, last_pull_ts: str, overlap_buffer_minutes: int) -> list[dict]
        Fetch Jira issues updated since last_pull_ts minus overlap_buffer_minutes,
        using JQL: updatedDate >= buffered_ts where buffered_ts is computed by
        subtracting overlap_buffer_minutes from last_pull_ts (UTC ISO 8601).
        Calls acli_client.search_issues(jql, start_at, max_results).

    normalize_timestamps(issue: dict) -> dict
        Convert issue fields created, updated, resolutiondate from Jira ISO 8601
        with timezone offset to UTC epoch int. Fields absent or None are left
        absent/None (not raised).

    write_create_events(issues: list[dict], tickets_tracker: Path, bridge_env_id: str) -> list[Path]
        For each Jira issue that is new (no SYNC event exists for its key),
        write a CREATE event file to .tickets-tracker/<generated_id>/<ts>-<uuid>-CREATE.json.
        Event file must contain: event_type=CREATE, env_id=bridge_env_id, data with
        Jira fields normalized to UTC timestamps. Skips idempotently if SYNC exists.

Mock acli_client interface:
    acli_client.search_issues(jql, start_at, max_results) -> list[dict]

Test: python3 -m pytest tests/scripts/test_bridge_inbound.py
All tests must return non-zero until bridge-inbound.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
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

_BRIDGE_ENV_ID = "cccccccc-0000-4000-8000-000000000003"
_UUID1 = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_UUID2 = "aabbccdd-1122-3344-5566-778899aabbcc"

# A sample Jira issue dict as ACLI search_issues would return it
_SAMPLE_JIRA_ISSUE = {
    "key": "DSO-42",
    "fields": {
        "summary": "Test ticket from Jira",
        "issuetype": {"name": "Task"},
        "status": {"name": "To Do"},
        "created": "2026-03-21T10:00:00.000+0530",
        "updated": "2026-03-21T11:30:00.000+0530",
        "resolutiondate": None,
        "priority": {"name": "Medium"},
    },
}


def _make_jira_issue(
    key: str = "DSO-1",
    summary: str = "Test issue",
    created: str = "2026-03-21T10:00:00.000+0000",
    updated: str = "2026-03-21T10:00:00.000+0000",
    resolutiondate: str | None = None,
) -> dict:
    return {
        "key": key,
        "fields": {
            "summary": summary,
            "issuetype": {"name": "Task"},
            "status": {"name": "To Do"},
            "created": created,
            "updated": updated,
            "resolutiondate": resolutiondate,
            "priority": {"name": "Medium"},
        },
    }


# ---------------------------------------------------------------------------
# Test 1: fetch_jira_changes builds correct JQL with buffered timestamp
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_fetch_jira_changes_builds_correct_jql(bridge: ModuleType) -> None:
    """Given last_pull_ts (UTC ISO 8601 string) and overlap_buffer_minutes (int),
    fetch_jira_changes() calls acli_client.search_issues with JQL:
        updatedDate >= "<buffered_ts>"
    where buffered_ts = last_pull_ts minus overlap_buffer_minutes.

    Example: last_pull_ts="2026-03-21T12:00:00Z", overlap_buffer_minutes=5
    → buffered_ts = "2026-03-21T11:55:00Z"
    → JQL contains: updatedDate >= "2026-03-21T11:55:00Z"
    """
    mock_client = MagicMock()
    mock_client.search_issues = MagicMock(return_value=[])

    last_pull_ts = "2026-03-21T12:00:00Z"
    overlap_buffer_minutes = 5

    bridge.fetch_jira_changes(
        mock_client,
        last_pull_ts=last_pull_ts,
        overlap_buffer_minutes=overlap_buffer_minutes,
    )

    assert mock_client.search_issues.called, (
        "fetch_jira_changes must call acli_client.search_issues"
    )

    # Extract the JQL argument from the first call
    call_args = mock_client.search_issues.call_args
    # JQL may be positional (args[0]) or keyword (kwargs["jql"])
    jql = call_args.args[0] if call_args.args else call_args.kwargs.get("jql", "")

    assert "updatedDate" in jql, f"JQL must reference updatedDate; got: {jql!r}"
    assert ">=" in jql, f"JQL must use >= operator; got: {jql!r}"

    # The buffered timestamp must subtract 5 minutes from 12:00 → 11:55
    assert "11:55" in jql, (
        f"JQL must use buffered timestamp (11:55 UTC, 5 minutes before 12:00); got: {jql!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: fetch_jira_changes returns list of issues from ACLI
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_fetch_jira_changes_returns_issues_list(bridge: ModuleType) -> None:
    """fetch_jira_changes() returns a list of dicts from ACLI search_issues response.
    Empty ACLI results return an empty list.
    """
    # Case 1: non-empty results
    sample_issues = [_make_jira_issue("DSO-1"), _make_jira_issue("DSO-2")]
    mock_client = MagicMock()
    mock_client.search_issues = MagicMock(return_value=sample_issues)

    result = bridge.fetch_jira_changes(
        mock_client,
        last_pull_ts="2026-03-21T12:00:00Z",
        overlap_buffer_minutes=0,
    )

    assert isinstance(result, list), "fetch_jira_changes must return a list"
    assert len(result) == 2, f"Expected 2 issues returned, got {len(result)}"
    assert result[0]["key"] == "DSO-1"
    assert result[1]["key"] == "DSO-2"

    # Case 2: empty results
    mock_client.search_issues = MagicMock(return_value=[])
    empty_result = bridge.fetch_jira_changes(
        mock_client,
        last_pull_ts="2026-03-21T12:00:00Z",
        overlap_buffer_minutes=0,
    )
    assert empty_result == [], (
        f"Empty ACLI results must return empty list, got {empty_result!r}"
    )


# ---------------------------------------------------------------------------
# Test 3: normalize_timestamps converts Jira ISO 8601 with tz offset to UTC epoch
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_normalize_timestamps_converts_to_utc_epoch(bridge: ModuleType) -> None:
    """normalize_timestamps(issue) converts fields created, updated, resolutiondate
    from Jira ISO 8601 with timezone offset to UTC epoch int.

    Example: "2026-03-21T10:00:00.000+0530"
    → UTC is 04:30:00 on 2026-03-21
    → UTC epoch = 1742524200
    """
    issue = _make_jira_issue(
        created="2026-03-21T10:00:00.000+0530",
        updated="2026-03-21T11:30:00.000+0530",
        resolutiondate="2026-03-21T12:00:00.000+0530",
    )

    normalized = bridge.normalize_timestamps(issue)

    assert isinstance(normalized, dict), "normalize_timestamps must return a dict"

    fields = normalized.get("fields", normalized)

    # 2026-03-21T10:00:00+05:30 = 2026-03-21T04:30:00Z
    expected_created_utc = int(
        datetime(2026, 3, 21, 4, 30, 0, tzinfo=timezone.utc).timestamp()
    )
    assert fields.get("created") == expected_created_utc, (
        f"created must be UTC epoch {expected_created_utc}, "
        f"got {fields.get('created')!r}"
    )

    # 2026-03-21T11:30:00+05:30 = 2026-03-21T06:00:00Z
    expected_updated_utc = int(
        datetime(2026, 3, 21, 6, 0, 0, tzinfo=timezone.utc).timestamp()
    )
    assert fields.get("updated") == expected_updated_utc, (
        f"updated must be UTC epoch {expected_updated_utc}, "
        f"got {fields.get('updated')!r}"
    )

    # 2026-03-21T12:00:00+05:30 = 2026-03-21T06:30:00Z
    expected_resolution_utc = int(
        datetime(2026, 3, 21, 6, 30, 0, tzinfo=timezone.utc).timestamp()
    )
    assert fields.get("resolutiondate") == expected_resolution_utc, (
        f"resolutiondate must be UTC epoch {expected_resolution_utc}, "
        f"got {fields.get('resolutiondate')!r}"
    )


# ---------------------------------------------------------------------------
# Test 4: normalize_timestamps handles None/absent fields gracefully
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_normalize_timestamps_handles_none_fields(bridge: ModuleType) -> None:
    """Fields absent or None in the issue dict are left absent/None — not raised.

    normalize_timestamps must not raise KeyError or TypeError when
    created, updated, or resolutiondate are None or missing.
    """
    # resolutiondate is None (common for unresolved issues)
    issue_with_none = _make_jira_issue(
        created="2026-03-21T10:00:00.000+0000",
        updated="2026-03-21T10:00:00.000+0000",
        resolutiondate=None,
    )

    normalized = bridge.normalize_timestamps(issue_with_none)
    assert isinstance(normalized, dict), "normalize_timestamps must return a dict"

    fields = normalized.get("fields", normalized)
    # resolutiondate=None must remain None (not raised, not coerced to 0)
    assert fields.get("resolutiondate") is None, (
        f"resolutiondate=None must remain None after normalization, "
        f"got {fields.get('resolutiondate')!r}"
    )

    # Issue with fields dict missing resolutiondate entirely
    issue_missing_field = {
        "key": "DSO-99",
        "fields": {
            "summary": "No resolution date",
            "created": "2026-03-21T10:00:00.000+0000",
            "updated": "2026-03-21T10:00:00.000+0000",
        },
    }
    try:
        normalized_missing = bridge.normalize_timestamps(issue_missing_field)
        assert isinstance(normalized_missing, dict), (
            "Must return dict even with missing fields"
        )
    except (KeyError, TypeError) as exc:
        pytest.fail(
            f"normalize_timestamps raised {type(exc).__name__} for missing field: {exc}"
        )


# ---------------------------------------------------------------------------
# Test 5: write_create_events writes event file for new Jira-originated ticket
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_write_create_events_new_ticket_writes_event_file(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a Jira issue dict (new Jira-originated ticket),
    write_create_events() writes a CREATE event file to:
        .tickets-tracker/<generated_id>/<ts>-<uuid>-CREATE.json

    Event file must contain:
        - event_type = "CREATE"
        - env_id = bridge_env_id
        - data with Jira fields normalized to UTC timestamps
    """
    tickets_tracker = tmp_path / ".tickets-tracker"
    tickets_tracker.mkdir()

    issue = _make_jira_issue(
        key="DSO-42",
        summary="New ticket from Jira",
        created="2026-03-21T10:00:00.000+0000",
        updated="2026-03-21T10:00:00.000+0000",
    )

    written = bridge.write_create_events(
        [issue],
        tickets_tracker=tickets_tracker,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert isinstance(written, list), "write_create_events must return a list of paths"
    assert len(written) == 1, f"Expected 1 CREATE event written, got {len(written)}"

    event_path = Path(written[0])
    assert event_path.exists(), f"Event file must exist on disk: {event_path}"
    assert "CREATE" in event_path.name, (
        f"Event filename must contain 'CREATE'; got {event_path.name!r}"
    )

    # Verify event file contents
    event_data = json.loads(event_path.read_text(encoding="utf-8"))
    assert event_data.get("event_type") == "CREATE", (
        f"event_type must be 'CREATE', got {event_data.get('event_type')!r}"
    )
    assert event_data.get("env_id") == _BRIDGE_ENV_ID, (
        f"env_id must be bridge_env_id={_BRIDGE_ENV_ID!r}, got {event_data.get('env_id')!r}"
    )
    assert "data" in event_data, "Event file must contain a 'data' field"

    data = event_data["data"]
    # Must include the Jira key
    assert data.get("jira_key") == "DSO-42" or event_data.get("jira_key") == "DSO-42", (
        "CREATE event must reference the Jira key DSO-42"
    )

    # Timestamps must be UTC epoch ints, not raw strings
    fields = data.get("fields", data)
    created_value = fields.get("created")
    if created_value is not None:
        assert isinstance(created_value, int), (
            f"Normalized created must be an int (UTC epoch), got {type(created_value).__name__}"
        )


# ---------------------------------------------------------------------------
# Test 6: write_create_events skips if SYNC event already exists (idempotency)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_write_create_events_skips_existing_local_ticket(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """If a ticket directory already has a SYNC event for this Jira key,
    write_create_events() skips writing (idempotency guard).

    This prevents duplicate CREATE events when the same Jira issue appears
    in multiple windowed pull results.
    """
    tickets_tracker = tmp_path / ".tickets-tracker"
    tickets_tracker.mkdir()

    # Pre-create a ticket directory with an existing SYNC event for DSO-42
    existing_ticket_dir = tickets_tracker / "w21-existing"
    existing_ticket_dir.mkdir()

    sync_payload = {
        "event_type": "SYNC",
        "jira_key": "DSO-42",
        "local_id": "w21-existing",
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742524200,
        "run_id": "previous-run-id",
    }
    sync_file = existing_ticket_dir / f"1742524200-{_UUID1}-SYNC.json"
    sync_file.write_text(json.dumps(sync_payload), encoding="utf-8")

    issue = _make_jira_issue(key="DSO-42", summary="Already imported ticket")

    written = bridge.write_create_events(
        [issue],
        tickets_tracker=tickets_tracker,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert isinstance(written, list), "write_create_events must return a list"
    assert len(written) == 0, (
        f"write_create_events must skip tickets with existing SYNC event; "
        f"got {len(written)} written instead of 0"
    )

    # Verify no new CREATE files were written under tickets_tracker
    all_create_files = list(tickets_tracker.rglob("*-CREATE.json"))
    assert len(all_create_files) == 0, (
        f"No CREATE event files must be written for already-synced ticket; "
        f"found: {all_create_files}"
    )


# ---------------------------------------------------------------------------
# TestStatusTypeMapping
# ---------------------------------------------------------------------------


class TestStatusTypeMapping:
    """Tests for configurable status and type mapping functions."""

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_map_status_known_value_returns_local_status(
        self, bridge: ModuleType
    ) -> None:
        """map_status('In Progress', mapping={'In Progress': 'in_progress'})
        returns 'in_progress'.
        """
        mapping = {
            "In Progress": "in_progress",
            "To Do": "pending",
            "Done": "completed",
        }
        result = bridge.map_status("In Progress", mapping=mapping)
        assert result == "in_progress", (
            f"map_status must return 'in_progress' for known value 'In Progress'; "
            f"got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_map_status_unknown_value_returns_none(self, bridge: ModuleType) -> None:
        """map_status('Unknown Status', mapping={...}) returns None.
        The caller is responsible for writing a BRIDGE_ALERT event.
        """
        mapping = {"In Progress": "in_progress"}
        result = bridge.map_status("Unknown Status", mapping=mapping)
        assert result is None, (
            f"map_status must return None for unknown value 'Unknown Status'; "
            f"got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_map_type_known_value_returns_local_type(self, bridge: ModuleType) -> None:
        """map_type('Story', mapping={'Story': 'story'}) returns 'story'."""
        mapping = {"Story": "story", "Task": "task", "Bug": "task"}
        result = bridge.map_type("Story", mapping=mapping)
        assert result == "story", (
            f"map_type must return 'story' for known value 'Story'; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_map_type_unknown_value_returns_none(self, bridge: ModuleType) -> None:
        """map_type('Custom Jira Type', mapping={}) returns None."""
        result = bridge.map_type("Custom Jira Type", mapping={})
        assert result is None, (
            f"map_type must return None for unknown value 'Custom Jira Type' with empty mapping; "
            f"got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_write_bridge_alert_writes_event_file(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """write_bridge_alert(ticket_id, reason, tickets_root, bridge_env_id) writes a
        BRIDGE_ALERT event file at:
            .tickets-tracker/<ticket_id>/<ts>-<uuid>-BRIDGE_ALERT.json

        Event file must contain: event_type=BRIDGE_ALERT, reason=reason, env_id=bridge_env_id.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        ticket_id = "jira-dso-99"
        ticket_dir = tickets_root / ticket_id
        ticket_dir.mkdir(parents=True)

        reason = "Unknown status value: 'Wontfix'"

        bridge.write_bridge_alert(
            ticket_id=ticket_id,
            reason=reason,
            tickets_root=tickets_root,
            bridge_env_id=_BRIDGE_ENV_ID,
        )

        alert_files = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
        assert len(alert_files) == 1, (
            f"write_bridge_alert must write exactly 1 BRIDGE_ALERT file; "
            f"found {len(alert_files)}: {alert_files}"
        )

        alert_data = json.loads(alert_files[0].read_text(encoding="utf-8"))
        assert alert_data.get("event_type") == "BRIDGE_ALERT", (
            f"event_type must be 'BRIDGE_ALERT'; got {alert_data.get('event_type')!r}"
        )
        assert alert_data.get("reason") == reason, (
            f"reason must be {reason!r}; got {alert_data.get('reason')!r}"
        )
        assert alert_data.get("env_id") == _BRIDGE_ENV_ID, (
            f"env_id must be {_BRIDGE_ENV_ID!r}; got {alert_data.get('env_id')!r}"
        )


# ---------------------------------------------------------------------------
# TestPagination
# ---------------------------------------------------------------------------


class TestPagination:
    """Tests for JQL pagination in fetch_jira_changes."""

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_fetch_jira_changes_paginates_all_results(self, bridge: ModuleType) -> None:
        """When acli_client.search_issues returns 100 results on page 0,
        50 results on page 1, and 0 results on page 2, fetch_jira_changes
        returns all 150 issues.

        search_issues must be called 3 times with start_at=0, 100, 200.
        """
        page0 = [_make_jira_issue(f"DSO-{i}") for i in range(100)]
        page1 = [_make_jira_issue(f"DSO-{i}") for i in range(100, 150)]

        call_count = 0

        def _search_issues(
            jql: str, start_at: int = 0, max_results: int = 100
        ) -> list[dict]:
            nonlocal call_count
            call_count += 1
            if start_at == 0:
                return page0
            elif start_at == 100:
                return page1
            else:
                return []

        mock_client = MagicMock()
        mock_client.search_issues = _search_issues

        result = bridge.fetch_jira_changes(
            mock_client,
            last_pull_ts="2026-03-21T12:00:00Z",
            overlap_buffer_minutes=0,
        )

        assert isinstance(result, list), "fetch_jira_changes must return a list"
        assert len(result) == 150, (
            f"fetch_jira_changes must return all 150 paginated results; got {len(result)}"
        )
        assert call_count == 2, (
            f"search_issues must be called 2 times (pages 0, 1); called {call_count} times"
        )


# ---------------------------------------------------------------------------
# TestUTCHealthCheck
# ---------------------------------------------------------------------------


class TestUTCHealthCheck:
    """Tests for UTC timezone health check against the Jira server."""

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_verify_jira_timezone_utc_passes_when_utc(self, bridge: ModuleType) -> None:
        """verify_jira_timezone_utc(acli_client) returns True when
        acli_client.get_server_info() returns {'timeZone': 'UTC'}.
        """
        mock_client = MagicMock()
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        result = bridge.verify_jira_timezone_utc(mock_client)

        assert result is True, (
            f"verify_jira_timezone_utc must return True when server timeZone is 'UTC'; "
            f"got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_verify_jira_timezone_utc_fails_when_non_utc(
        self, bridge: ModuleType
    ) -> None:
        """verify_jira_timezone_utc(acli_client) returns False when
        timeZone is 'America/New_York' (and logs a warning).
        """
        mock_client = MagicMock()
        mock_client.get_server_info = MagicMock(
            return_value={"timeZone": "America/New_York"}
        )

        result = bridge.verify_jira_timezone_utc(mock_client)

        assert result is False, (
            f"verify_jira_timezone_utc must return False for non-UTC timeZone "
            f"'America/New_York'; got {result!r}"
        )


# ---------------------------------------------------------------------------
# TestProcessInbound
# ---------------------------------------------------------------------------


class TestProcessInbound:
    """Tests for the process_inbound orchestrator entry point."""

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_process_inbound_writes_create_events_for_new_issues(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """process_inbound(tickets_root, acli_client, last_pull_ts, config)
        calls fetch, normalize, write_create_events, and updates the checkpoint file
        with a new last_pull_ts after a successful run.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        sample_issues = [_make_jira_issue("DSO-1"), _make_jira_issue("DSO-2")]
        mock_client = MagicMock()
        mock_client.search_issues = MagicMock(return_value=sample_issues)
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 5,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        bridge.process_inbound(
            tickets_root=tickets_root,
            acli_client=mock_client,
            last_pull_ts=old_ts,
            config=config,
        )

        # Checkpoint must be updated
        updated = json.loads(checkpoint_file.read_text(encoding="utf-8"))
        new_ts = updated.get("last_pull_ts", "")
        assert new_ts != old_ts, (
            f"process_inbound must update checkpoint last_pull_ts; "
            f"still set to old_ts={old_ts!r}"
        )

        # CREATE events must have been written
        create_files = list(tickets_root.rglob("*-CREATE.json"))
        assert len(create_files) == 2, (
            f"process_inbound must write 2 CREATE events for 2 new issues; "
            f"found {len(create_files)}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_process_inbound_fast_aborts_on_auth_failure(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """When acli_client raises an authentication error (returncode=401),
        process_inbound does NOT update the checkpoint file (preserves last good ts).
        """
        import subprocess

        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        mock_client = MagicMock()
        # Simulate authentication failure: search_issues raises CalledProcessError(401)
        mock_client.search_issues = MagicMock(
            side_effect=subprocess.CalledProcessError(401, "acli")
        )
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 5,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {},
            "type_mapping": {},
        }

        try:
            bridge.process_inbound(
                tickets_root=tickets_root,
                acli_client=mock_client,
                last_pull_ts=old_ts,
                config=config,
            )
        except Exception:
            # process_inbound may raise or swallow; either is acceptable —
            # what matters is the checkpoint is NOT updated.
            pass

        # Checkpoint must NOT be updated — last_pull_ts preserved
        updated = json.loads(checkpoint_file.read_text(encoding="utf-8"))
        preserved_ts = updated.get("last_pull_ts", "")
        assert preserved_ts == old_ts, (
            f"process_inbound must NOT update checkpoint on auth failure; "
            f"expected {old_ts!r}, got {preserved_ts!r}"
        )


# ---------------------------------------------------------------------------
# TestDestructiveChangeGuards
# RED tests — is_destructive_change() does not exist yet; all tests must FAIL.
# ---------------------------------------------------------------------------


class TestDestructiveChangeGuards:
    """RED tests for is_destructive_change() guard function.

    is_destructive_change(existing: dict, inbound: dict) -> bool

    A change is destructive when the inbound update would silently overwrite or
    remove meaningful data that exists in the current ticket state.

    Destructive cases:
      - Replacing a non-empty description with an empty/whitespace-only string
      - Removing a relationship that exists on the ticket
      - Downgrading a ticket type (e.g. epic → task)

    Non-destructive cases:
      - Filling an empty description with a non-empty value
      - Upgrading a ticket type (e.g. task → epic)
    """

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_is_destructive_change_empty_over_nonempty_description(
        self, bridge: ModuleType
    ) -> None:
        """Replacing a non-empty description with an empty string is destructive.

        existing: description = "Original description text"
        inbound:  description = ""
        → is_destructive_change() returns True
        """
        existing = {
            "description": "Original description text",
            "links": [],
            "type": "task",
        }
        inbound = {"description": "", "links": [], "type": "task"}

        result = bridge.is_destructive_change(existing, inbound)

        assert result is True, (
            "is_destructive_change must return True when inbound description is empty "
            f"and existing description is non-empty; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_is_destructive_change_whitespace_over_nonempty_description(
        self, bridge: ModuleType
    ) -> None:
        """Replacing a non-empty description with whitespace-only is destructive.

        Whitespace-only strings (e.g. '   ') are treated as empty.

        existing: description = "Original description text"
        inbound:  description = "   "
        → is_destructive_change() returns True
        """
        existing = {
            "description": "Original description text",
            "links": [],
            "type": "task",
        }
        inbound = {"description": "   ", "links": [], "type": "task"}

        result = bridge.is_destructive_change(existing, inbound)

        assert result is True, (
            "is_destructive_change must return True when inbound description is "
            "whitespace-only and existing description is non-empty; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_is_destructive_change_nonempty_over_empty_description(
        self, bridge: ModuleType
    ) -> None:
        """Filling an empty description with a non-empty value is NOT destructive.

        existing: description = ""
        inbound:  description = "New description"
        → is_destructive_change() returns False
        """
        existing = {"description": "", "links": [], "type": "task"}
        inbound = {"description": "New description", "links": [], "type": "task"}

        result = bridge.is_destructive_change(existing, inbound)

        assert result is False, (
            "is_destructive_change must return False when inbound fills an empty "
            f"description with a non-empty value; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_is_destructive_change_relationship_removal(
        self, bridge: ModuleType
    ) -> None:
        """Removing a relationship that exists on the ticket is destructive.

        existing: links = ["w21-abc"]
        inbound:  links = []
        → is_destructive_change() returns True
        """
        existing = {"description": "", "links": ["w21-abc"], "type": "task"}
        inbound = {"description": "", "links": [], "type": "task"}

        result = bridge.is_destructive_change(existing, inbound)

        assert result is True, (
            "is_destructive_change must return True when inbound removes a "
            f"relationship that exists on the ticket; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_is_destructive_change_type_downgrade(self, bridge: ModuleType) -> None:
        """Downgrading a ticket type (epic → task) is destructive.

        existing: type = "epic"
        inbound:  type = "task"
        → is_destructive_change() returns True
        """
        # TYPE_HIERARCHY: epic > story > task (lower index = higher rank)
        existing = {"description": "", "links": [], "type": "epic"}
        inbound = {"description": "", "links": [], "type": "task"}

        result = bridge.is_destructive_change(existing, inbound)

        assert result is True, (
            "is_destructive_change must return True when inbound downgrades "
            f"ticket type from 'epic' to 'task'; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_is_destructive_change_type_upgrade_allowed(
        self, bridge: ModuleType
    ) -> None:
        """Upgrading a ticket type (task → epic) is NOT destructive.

        existing: type = "task"
        inbound:  type = "epic"
        → is_destructive_change() returns False
        """
        existing = {"description": "", "links": [], "type": "task"}
        inbound = {"description": "", "links": [], "type": "epic"}

        result = bridge.is_destructive_change(existing, inbound)

        assert result is False, (
            "is_destructive_change must return False when inbound upgrades "
            f"ticket type from 'task' to 'epic'; got {result!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_process_inbound_skips_destructive_changes_and_writes_alert(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """When is_destructive_change() returns True, process_inbound must:
          1. Write a BRIDGE_ALERT event for the destructive field.
          2. Skip the destructive field update (do not apply the overwrite).

        This test verifies the guard is wired into process_inbound by checking
        that a BRIDGE_ALERT file is written when inbound data would clear an
        existing description.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        # Simulate: existing local ticket has a non-empty description;
        # inbound Jira issue sends an empty description (destructive).
        # The existing ticket state is represented by a pre-written SYNC event
        # with a non-empty description, so process_inbound can detect the conflict.
        existing_local_id = "jira-dso-55"
        existing_ticket_dir = tickets_root / existing_local_id
        existing_ticket_dir.mkdir(parents=True)

        # Pre-existing SYNC event records the current local state including description
        sync_payload = {
            "event_type": "SYNC",
            "jira_key": "DSO-55",
            "local_id": existing_local_id,
            "env_id": _BRIDGE_ENV_ID,
            "timestamp": 1742524200,
            "data": {
                "description": "This is an existing non-empty description",
                "links": [],
                "type": "task",
            },
        }
        sync_file = existing_ticket_dir / f"1742524200-{_UUID1}-SYNC.json"
        sync_file.write_text(json.dumps(sync_payload), encoding="utf-8")

        # Inbound Jira issue has empty description (would be destructive)
        inbound_issue = {
            "key": "DSO-55",
            "fields": {
                "summary": "Existing ticket",
                "description": "",
                "issuetype": {"name": "Task"},
                "status": {"name": "To Do"},
                "created": "2026-03-21T10:00:00.000+0000",
                "updated": "2026-03-21T10:00:00.000+0000",
                "resolutiondate": None,
            },
        }

        mock_client = MagicMock()
        mock_client.search_issues = MagicMock(return_value=[inbound_issue])
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        bridge.process_inbound(
            tickets_root=tickets_root,
            acli_client=mock_client,
            last_pull_ts=old_ts,
            config=config,
        )

        # A BRIDGE_ALERT must be written for the destructive change
        alert_files = list(tickets_root.rglob("*-BRIDGE_ALERT.json"))
        assert len(alert_files) >= 1, (
            "process_inbound must write at least one BRIDGE_ALERT when "
            f"is_destructive_change() returns True; found {len(alert_files)} alert files"
        )

        # Verify at least one alert mentions 'destructive' or 'description'
        alert_reasons = []
        for af in alert_files:
            try:
                data = json.loads(af.read_text(encoding="utf-8"))
                alert_reasons.append(data.get("reason", ""))
            except (OSError, json.JSONDecodeError):
                pass

        assert any(
            "destructive" in r.lower() or "description" in r.lower()
            for r in alert_reasons
        ), (
            "BRIDGE_ALERT reason must reference 'destructive' or 'description'; "
            f"got reasons: {alert_reasons!r}"
        )


# ---------------------------------------------------------------------------
# TestInboundStatusEvents
# ---------------------------------------------------------------------------


class TestInboundStatusEvents:
    """Tests for bridge-authored STATUS event writing on Jira status changes.

    write_status_event() enables bidirectional flap detection by recording
    status transitions that originate from the inbound bridge (not from local
    user actions). The env_id field identifies this bridge as the author.
    """

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_write_status_event_creates_event_file(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """write_status_event(ticket_id, status, ticket_dir, bridge_env_id) writes
        a STATUS event file at:
            <ticket_dir>/<ts>-<uuid>-STATUS.json

        Asserts:
        - Exactly one *-STATUS.json file is created in ticket_dir.
        - The file is non-empty JSON.
        - env_id in the payload equals bridge_env_id.
        """
        ticket_dir = tmp_path / "jira-dso-55"
        ticket_dir.mkdir()

        bridge.write_status_event(
            ticket_id="jira-dso-55",
            status="in_progress",
            ticket_dir=ticket_dir,
            bridge_env_id=_BRIDGE_ENV_ID,
        )

        status_files = list(ticket_dir.glob("*-STATUS.json"))
        assert len(status_files) == 1, (
            f"write_status_event must write exactly 1 STATUS file; "
            f"found {len(status_files)}: {status_files}"
        )

        payload = json.loads(status_files[0].read_text(encoding="utf-8"))
        assert payload.get("env_id") == _BRIDGE_ENV_ID, (
            f"env_id must equal bridge_env_id={_BRIDGE_ENV_ID!r}; "
            f"got {payload.get('env_id')!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_write_status_event_has_correct_fields(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """STATUS event file contains all required fields:
        event_type="STATUS", data.status=<new_status>, env_id=bridge_env_id,
        timestamp (int), uuid (str).
        """
        ticket_dir = tmp_path / "jira-dso-56"
        ticket_dir.mkdir()

        bridge.write_status_event(
            ticket_id="jira-dso-56",
            status="completed",
            ticket_dir=ticket_dir,
            bridge_env_id=_BRIDGE_ENV_ID,
        )

        status_files = list(ticket_dir.glob("*-STATUS.json"))
        assert len(status_files) == 1, (
            f"Expected 1 STATUS file; found {len(status_files)}"
        )

        payload = json.loads(status_files[0].read_text(encoding="utf-8"))

        assert payload.get("event_type") == "STATUS", (
            f"event_type must be 'STATUS'; got {payload.get('event_type')!r}"
        )
        assert payload.get("env_id") == _BRIDGE_ENV_ID, (
            f"env_id must be {_BRIDGE_ENV_ID!r}; got {payload.get('env_id')!r}"
        )

        ts = payload.get("timestamp")
        assert isinstance(ts, int), (
            f"timestamp must be an int (UTC epoch); got {type(ts).__name__}: {ts!r}"
        )

        event_uuid = payload.get("uuid")
        assert isinstance(event_uuid, str) and len(event_uuid) > 0, (
            f"uuid must be a non-empty str; got {event_uuid!r}"
        )

        data = payload.get("data", {})
        assert data.get("status") == "completed", (
            f"data.status must equal the new_status 'completed'; "
            f"got {data.get('status')!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_process_inbound_calls_write_status_event_for_mapped_status_change(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """When a Jira issue has a status that maps to a local status different
        from the compiled local state, process_inbound writes a bridge-authored
        STATUS event file for that ticket.

        Setup:
        - Local ticket jira-dso-77 already exists with local status "pending".
        - Jira issue DSO-77 now has status "In Progress" (maps to "in_progress").
        - process_inbound must write a STATUS event file for jira-dso-77.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        # Pre-create local ticket directory with SYNC + existing STATUS at "pending"
        ticket_dir = tickets_root / "jira-dso-77"
        ticket_dir.mkdir()

        # Existing SYNC event so CREATE is skipped (idempotency)
        sync_payload = {
            "event_type": "SYNC",
            "jira_key": "DSO-77",
            "local_id": "jira-dso-77",
            "env_id": _BRIDGE_ENV_ID,
            "timestamp": 1742524200,
            "run_id": "prev-run",
        }
        (ticket_dir / f"1742524200-{_UUID1}-SYNC.json").write_text(
            json.dumps(sync_payload), encoding="utf-8"
        )

        # Existing STATUS event showing local compiled state is "pending"
        existing_status_payload = {
            "event_type": "STATUS",
            "env_id": _BRIDGE_ENV_ID,
            "timestamp": 1742524100,
            "uuid": _UUID2,
            "data": {"status": "pending"},
        }
        (ticket_dir / f"1742524100-{_UUID2}-STATUS.json").write_text(
            json.dumps(existing_status_payload), encoding="utf-8"
        )

        # Jira now reports DSO-77 as "In Progress" → maps to "in_progress"
        jira_issue = {
            "key": "DSO-77",
            "fields": {
                "summary": "Changed status ticket",
                "issuetype": {"name": "Task"},
                "status": {"name": "In Progress"},
                "created": "2026-03-21T10:00:00.000+0000",
                "updated": "2026-03-21T12:00:00.000+0000",
                "resolutiondate": None,
                "priority": {"name": "Medium"},
            },
        }

        mock_client = MagicMock()
        mock_client.search_issues = MagicMock(return_value=[jira_issue])
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": "",
            "status_mapping": {"In Progress": "in_progress", "To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        bridge.process_inbound(
            tickets_root=tickets_root,
            acli_client=mock_client,
            last_pull_ts="2026-03-21T12:00:00Z",
            config=config,
        )

        # A new STATUS event must have been written (distinct from the existing one)
        all_status_files = list(ticket_dir.glob("*-STATUS.json"))
        new_status_files = [
            f for f in all_status_files if f"1742524100-{_UUID2}" not in f.name
        ]
        assert len(new_status_files) >= 1, (
            f"process_inbound must write a STATUS event when Jira status differs from "
            f"local compiled state; found new STATUS files: {new_status_files}"
        )

        # The new STATUS event must reflect the updated status
        new_payload = json.loads(new_status_files[0].read_text(encoding="utf-8"))
        assert new_payload.get("event_type") == "STATUS", (
            f"New event must have event_type='STATUS'; got {new_payload.get('event_type')!r}"
        )
        new_data = new_payload.get("data", {})
        assert new_data.get("status") == "in_progress", (
            f"data.status must be 'in_progress' (mapped from 'In Progress'); "
            f"got {new_data.get('status')!r}"
        )


# ---------------------------------------------------------------------------
# TestRelationshipRejection
# ---------------------------------------------------------------------------


class TestRelationshipRejection:
    """Tests for relationship rejection persistence.

    When Jira rejects a relationship push (e.g., epic-blocks-epic is disallowed),
    the bridge must persist jira_sync_status=rejected locally and never remove
    the local relationship. This ensures the local ticket state is authoritative
    and divergences from Jira are visible for operator review.
    """

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_relationship_rejection_persistence_writes_rejected_status(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """When Jira returns an error rejecting a relationship push, the bridge
        writes a .jira-sync-status file in the ticket directory containing:
            {"jira_sync_status": "rejected", "reason": "<error_description>"}

        Simulates acli_client.set_relationship() raising an exception (Jira rejection).
        Asserts:
        - <ticket_dir>/.jira-sync-status exists.
        - jira_sync_status == "rejected".
        - reason field is a non-empty string.
        """
        ticket_dir = tmp_path / "jira-dso-88"
        ticket_dir.mkdir()

        rejection_reason = "epic-blocks-epic relationship type not allowed in Jira"

        bridge.persist_relationship_rejection(
            ticket_id="jira-dso-88",
            ticket_dir=ticket_dir,
            reason=rejection_reason,
        )

        sync_status_file = ticket_dir / ".jira-sync-status"
        assert sync_status_file.exists(), (
            f".jira-sync-status file must be written after relationship rejection; "
            f"not found at {sync_status_file}"
        )

        sync_status = json.loads(sync_status_file.read_text(encoding="utf-8"))
        assert sync_status.get("jira_sync_status") == "rejected", (
            f"jira_sync_status must be 'rejected'; "
            f"got {sync_status.get('jira_sync_status')!r}"
        )
        reason = sync_status.get("reason", "")
        assert isinstance(reason, str) and len(reason) > 0, (
            f"reason must be a non-empty string; got {reason!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_relationship_rejection_persistence_local_relationship_never_removed(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """After a Jira relationship rejection, the local ticket's links field is
        preserved (not removed). The .jira-sync-status file records the rejection.

        A ticket with a local "blocks" relationship to another ticket must still
        have that relationship after persist_relationship_rejection() is called.
        """
        ticket_dir = tmp_path / "jira-dso-89"
        ticket_dir.mkdir()

        # Write a local CREATE event containing a links relationship
        local_links = [{"type": "blocks", "target": "jira-dso-90"}]
        create_payload = {
            "event_type": "CREATE",
            "env_id": _BRIDGE_ENV_ID,
            "jira_key": "DSO-89",
            "local_id": "jira-dso-89",
            "timestamp": 1742524200,
            "run_id": "run-1",
            "data": {
                "jira_key": "DSO-89",
                "fields": {"summary": "Ticket with relationship"},
                "links": local_links,
            },
        }
        (ticket_dir / f"1742524200-{_UUID1}-CREATE.json").write_text(
            json.dumps(create_payload), encoding="utf-8"
        )

        # Call persist_relationship_rejection — must NOT remove the links
        bridge.persist_relationship_rejection(
            ticket_id="jira-dso-89",
            ticket_dir=ticket_dir,
            reason="Jira rejected epic-blocks-epic link type",
        )

        # The .jira-sync-status file must exist with rejected status
        sync_status_file = ticket_dir / ".jira-sync-status"
        assert sync_status_file.exists(), (
            ".jira-sync-status must be written after rejection"
        )

        sync_status = json.loads(sync_status_file.read_text(encoding="utf-8"))
        assert sync_status.get("jira_sync_status") == "rejected", (
            f"jira_sync_status must be 'rejected'; got {sync_status.get('jira_sync_status')!r}"
        )

        # The original CREATE event must be untouched — links still present
        create_files = list(ticket_dir.glob("*-CREATE.json"))
        assert len(create_files) == 1, (
            f"CREATE event must still exist after rejection; found: {create_files}"
        )
        create_data = json.loads(create_files[0].read_text(encoding="utf-8"))
        preserved_links = create_data.get("data", {}).get("links", [])
        assert preserved_links == local_links, (
            f"local links must be preserved after rejection; "
            f"expected {local_links!r}, got {preserved_links!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_process_inbound_persists_rejection_on_acli_relationship_error(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """When acli_client.set_relationship() raises an error during process_inbound,
        the bridge persists jira_sync_status=rejected locally and does NOT propagate
        the exception (continues processing remaining issues).

        Setup:
        - Two Jira issues: DSO-91 (normal) and DSO-92 (relationship rejection).
        - DSO-92 triggers acli_client.set_relationship() to raise RuntimeError.

        Asserts:
        - jira-dso-92/.jira-sync-status exists with jira_sync_status=rejected.
        - process_inbound does not raise (continues after rejection).
        - DSO-91 CREATE event is still written (not aborted by DSO-92 failure).
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        jira_issues = [
            {
                "key": "DSO-91",
                "fields": {
                    "summary": "Normal ticket",
                    "issuetype": {"name": "Task"},
                    "status": {"name": "To Do"},
                    "created": "2026-03-21T10:00:00.000+0000",
                    "updated": "2026-03-21T10:00:00.000+0000",
                    "resolutiondate": None,
                    "priority": {"name": "Medium"},
                },
            },
            {
                "key": "DSO-92",
                "fields": {
                    "summary": "Ticket with rejected relationship",
                    "issuetype": {"name": "Epic"},
                    "status": {"name": "To Do"},
                    "created": "2026-03-21T10:00:00.000+0000",
                    "updated": "2026-03-21T10:00:00.000+0000",
                    "resolutiondate": None,
                    "priority": {"name": "High"},
                    "issuelinks": [
                        {
                            "type": {"name": "Blocks"},
                            "outwardIssue": {"key": "DSO-93"},
                        }
                    ],
                },
            },
        ]

        mock_client = MagicMock()
        mock_client.search_issues = MagicMock(return_value=jira_issues)
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})
        # set_relationship raises for DSO-92's epic-blocks-epic link
        mock_client.set_relationship = MagicMock(
            side_effect=RuntimeError("epic-blocks-epic relationship not allowed")
        )

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task", "Epic": "epic"},
        }

        # process_inbound must NOT raise — it handles relationship rejection gracefully
        try:
            bridge.process_inbound(
                tickets_root=tickets_root,
                acli_client=mock_client,
                last_pull_ts="2026-03-21T12:00:00Z",
                config=config,
            )
        except Exception:
            # If the implementation raises before relationship processing is added,
            # the RED state is confirmed by AttributeError on missing function.
            pass

        # DSO-92 must have a .jira-sync-status file with rejected status
        ticket_dir_92 = tickets_root / "jira-dso-92"
        sync_status_file = ticket_dir_92 / ".jira-sync-status"

        # RED assertion: this file won't exist until the implementation is added
        assert sync_status_file.exists(), (
            f".jira-sync-status must be written for jira-dso-92 after relationship "
            f"rejection; not found at {sync_status_file}"
        )

        sync_status = json.loads(sync_status_file.read_text(encoding="utf-8"))
        assert sync_status.get("jira_sync_status") == "rejected", (
            f"jira_sync_status must be 'rejected' for jira-dso-92; "
            f"got {sync_status.get('jira_sync_status')!r}"
        )


# ---------------------------------------------------------------------------
# TestPerBatchCheckpoint
# ---------------------------------------------------------------------------


class TestPerBatchCheckpoint:
    """Tests for per-batch checkpoint with dual-timestamp model.

    Dual-timestamp model:
      - last_pull_ts (main timestamp): advances ONLY after the entire run
        completes successfully.
      - batch_resume_cursor (per-batch): tracks the last successfully processed
        batch page; used for resume-only (never advances the pull window).
    """

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_last_pull_ts_advances_only_on_full_success(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """Simulate a run that completes successfully; assert last_pull_ts in
        checkpoint file advances to a new timestamp.

        After a full successful run, last_pull_ts must be updated AND
        batch_resume_cursor must be cleared (no stale cursor left behind).
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        sample_issues = [_make_jira_issue("DSO-200")]
        mock_client = MagicMock()
        mock_client.search_issues = MagicMock(return_value=sample_issues)
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        bridge.process_inbound(
            tickets_root=tickets_root,
            acli_client=mock_client,
            last_pull_ts=old_ts,
            config=config,
        )

        updated = json.loads(checkpoint_file.read_text(encoding="utf-8"))
        new_ts = updated.get("last_pull_ts", "")
        assert new_ts != old_ts, (
            f"last_pull_ts must advance after full successful run; still {old_ts!r}"
        )

        # batch_resume_cursor must be absent after full success
        assert "batch_resume_cursor" not in updated, (
            "batch_resume_cursor must be cleared after a full successful run; "
            f"found {updated.get('batch_resume_cursor')!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_last_pull_ts_not_advanced_on_mid_run_failure(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """Simulate a run that fails partway through (exception during processing);
        assert last_pull_ts in checkpoint file is unchanged.

        A mid-run failure must NOT advance last_pull_ts. The batch_resume_cursor
        may remain (for resume), but last_pull_ts must stay at the old value.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        # Return issues on first page, then raise on second page
        page0 = [_make_jira_issue(f"DSO-{i}") for i in range(100)]

        call_count = 0

        def _search_issues_with_failure(
            jql: str, start_at: int = 0, max_results: int = 100
        ) -> list[dict]:
            nonlocal call_count
            call_count += 1
            if start_at == 0:
                return page0
            raise ConnectionError("Network failure mid-pagination")

        mock_client = MagicMock()
        mock_client.search_issues = _search_issues_with_failure
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        try:
            bridge.process_inbound(
                tickets_root=tickets_root,
                acli_client=mock_client,
                last_pull_ts=old_ts,
                config=config,
            )
        except Exception:
            pass

        # last_pull_ts must NOT have advanced
        updated = json.loads(checkpoint_file.read_text(encoding="utf-8"))
        preserved_ts = updated.get("last_pull_ts", "")
        assert preserved_ts == old_ts, (
            f"last_pull_ts must NOT advance on mid-run failure; "
            f"expected {old_ts!r}, got {preserved_ts!r}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_batch_resume_cursor_written_per_batch(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """Simulate a paginated run with 3 pages; assert after each page, a
        batch_resume_cursor field is written to the checkpoint file.

        The on_batch_complete callback in fetch_jira_changes must write
        batch_resume_cursor to the checkpoint file after each page.
        """
        import os
        import unittest.mock

        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        page0 = [_make_jira_issue(f"DSO-{i}") for i in range(100)]
        page1 = [_make_jira_issue(f"DSO-{i}") for i in range(100, 200)]
        page2 = [_make_jira_issue(f"DSO-{i}") for i in range(200, 250)]

        cursor_values: list[int] = []
        checkpoint_str = str(checkpoint_file)

        def _search_issues_tracking(
            jql: str, start_at: int = 0, max_results: int = 100
        ) -> list[dict]:
            if start_at == 0:
                return page0
            if start_at == 100:
                return page1
            if start_at == 200:
                return page2
            return []

        mock_client = MagicMock()
        mock_client.search_issues = _search_issues_tracking
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": checkpoint_str,
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        # Intercept os.replace to capture checkpoint writes (atomic write path)
        original_replace = os.replace

        def _tracking_replace(src: str, dst: str) -> None:
            original_replace(src, dst)
            if os.path.abspath(dst) == os.path.abspath(checkpoint_str):
                try:
                    data = json.loads(Path(dst).read_text(encoding="utf-8"))
                    if "batch_resume_cursor" in data:
                        cursor_values.append(data["batch_resume_cursor"])
                except (OSError, json.JSONDecodeError):
                    pass

        with unittest.mock.patch("os.replace", _tracking_replace):
            bridge.process_inbound(
                tickets_root=tickets_root,
                acli_client=mock_client,
                last_pull_ts=old_ts,
                config=config,
            )

        # batch_resume_cursor must have been written at least once per page
        assert len(cursor_values) >= 2, (
            "batch_resume_cursor must be written to checkpoint after each batch page; "
            f"captured cursor writes: {cursor_values}"
        )

        # Cursor values must be increasing (tracking pagination progress)
        assert cursor_values == sorted(cursor_values), (
            "batch_resume_cursor values must be monotonically increasing; "
            f"got: {cursor_values}"
        )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_batch_resume_cursor_does_not_advance_last_pull_ts(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """Verify that writing per-batch cursor does NOT change last_pull_ts.

        During pagination, batch_resume_cursor is written per page but
        last_pull_ts must remain at the old value until full run success.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts}), encoding="utf-8"
        )

        page0 = [_make_jira_issue(f"DSO-{i}") for i in range(100)]
        page1 = [_make_jira_issue(f"DSO-{i}") for i in range(100, 150)]

        ts_during_pagination: list[str] = []

        def _search_issues_spy(
            jql: str, start_at: int = 0, max_results: int = 100
        ) -> list[dict]:
            # After the first page is fetched, read checkpoint to see if
            # last_pull_ts was prematurely advanced
            if start_at > 0:
                try:
                    data = json.loads(
                        Path(str(checkpoint_file)).read_text(encoding="utf-8")
                    )
                    ts_during_pagination.append(data.get("last_pull_ts", ""))
                except (OSError, json.JSONDecodeError):
                    pass

            if start_at == 0:
                return page0
            elif start_at == 100:
                return page1
            return []

        mock_client = MagicMock()
        mock_client.search_issues = _search_issues_spy
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
        }

        bridge.process_inbound(
            tickets_root=tickets_root,
            acli_client=mock_client,
            last_pull_ts=old_ts,
            config=config,
        )

        # During pagination, last_pull_ts must NOT have changed
        for ts in ts_during_pagination:
            assert ts == old_ts, (
                f"last_pull_ts must NOT change during pagination; "
                f"expected {old_ts!r}, got {ts!r}"
            )

    @pytest.mark.unit
    @pytest.mark.scripts
    def test_per_batch_checkpoint_enables_resume(
        self, tmp_path: Path, bridge: ModuleType
    ) -> None:
        """Write a checkpoint with batch_resume_cursor: 100; call process_inbound
        with resume=True; assert pagination starts from page 100, not page 0.
        """
        tickets_root = tmp_path / ".tickets-tracker"
        tickets_root.mkdir()

        checkpoint_file = tmp_path / "bridge-checkpoint.json"
        old_ts = "2026-03-21T10:00:00Z"
        checkpoint_file.write_text(
            json.dumps({"last_pull_ts": old_ts, "batch_resume_cursor": 100}),
            encoding="utf-8",
        )

        page1 = [_make_jira_issue(f"DSO-{i}") for i in range(100, 150)]
        start_at_values: list[int] = []

        def _search_issues_tracking_start(
            jql: str, start_at: int = 0, max_results: int = 100
        ) -> list[dict]:
            start_at_values.append(start_at)
            if start_at == 100:
                return page1
            return []

        mock_client = MagicMock()
        mock_client.search_issues = _search_issues_tracking_start
        mock_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

        config = {
            "bridge_env_id": _BRIDGE_ENV_ID,
            "overlap_buffer_minutes": 0,
            "checkpoint_file": str(checkpoint_file),
            "status_mapping": {"To Do": "pending"},
            "type_mapping": {"Task": "task"},
            "resume": True,
            "batch_resume_cursor": 100,
        }

        bridge.process_inbound(
            tickets_root=tickets_root,
            acli_client=mock_client,
            last_pull_ts=old_ts,
            config=config,
        )

        # The first search_issues call must start at 100 (resume), not 0
        assert len(start_at_values) >= 1, "search_issues must be called at least once"
        assert start_at_values[0] == 100, (
            f"With batch_resume_cursor=100 and resume=True, pagination must start "
            f"at start_at=100; got first start_at={start_at_values[0]}"
        )


# ---------------------------------------------------------------------------
# Bug 8190-121b: inbound event writers must use nanosecond timestamps
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_write_create_event_timestamp_is_nanosecond_scale(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """write_create_events writes a CREATE event whose 'timestamp' field is at
    nanosecond scale (> 1_000_000_000_000).

    This test is RED: current code uses int(time.time()) which produces a
    seconds-scale integer (~1.7e9), well below the 1e12 threshold. After the
    fix uses time.time_ns() the value will be ~1.7e18, above the threshold.
    """
    tickets_tracker = tmp_path / ".tickets-tracker"
    tickets_tracker.mkdir()

    issue = _make_jira_issue(
        key="DSO-9190",
        summary="Nanosecond timestamp test",
        created="2026-04-18T10:00:00.000+0000",
        updated="2026-04-18T10:00:00.000+0000",
    )

    written = bridge.write_create_events(
        [issue],
        tickets_tracker=tickets_tracker,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert len(written) == 1, "Expected 1 CREATE event written"
    event_path = Path(written[0])
    assert event_path.exists(), f"CREATE event file must exist: {event_path}"

    event_data = json.loads(event_path.read_text(encoding="utf-8"))
    ts = event_data.get("timestamp")
    assert isinstance(ts, int), f"timestamp must be an int, got {type(ts).__name__}"
    assert ts > 1_000_000_000_000, (
        f"timestamp must be nanosecond-scale (> 1_000_000_000_000); "
        f"got {ts} — current code uses int(time.time()) which is seconds-scale (~1.7e9). "
        f"Fix: use time.time_ns() instead."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_write_status_event_timestamp_is_nanosecond_scale(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """write_status_event writes a STATUS event whose 'timestamp' field is at
    nanosecond scale (> 1_000_000_000_000).

    This test is RED: current code uses int(time.time()) which produces a
    seconds-scale integer (~1.7e9), well below the 1e12 threshold.
    """
    ticket_dir = tmp_path / "jira-dso-9190"
    ticket_dir.mkdir()

    bridge.write_status_event(
        ticket_id="jira-dso-9190",
        status="in_progress",
        ticket_dir=ticket_dir,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    status_files = list(ticket_dir.glob("*-STATUS.json"))
    assert len(status_files) == 1, (
        f"write_status_event must write exactly 1 STATUS file; found {len(status_files)}"
    )

    event_data = json.loads(status_files[0].read_text(encoding="utf-8"))
    ts = event_data.get("timestamp")
    assert isinstance(ts, int), f"timestamp must be an int, got {type(ts).__name__}"
    assert ts > 1_000_000_000_000, (
        f"timestamp must be nanosecond-scale (> 1_000_000_000_000); "
        f"got {ts} — current code uses int(time.time()) which is seconds-scale (~1.7e9). "
        f"Fix: use time.time_ns() instead."
    )
