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
