"""Tests for Jira delete_issue + inbound guard (story bbe3-bd36).

Covers:
  (a) 200 delete success path
  (b) 404 idempotent path (treated as success)
  (c) 403 BRIDGE_ALERT path (skip deletion, write alert, no crash)
  (d) missing jira_key skip path (ticket not synced — silent debug log)
  (e) inbound guard skips writing events for deleted/archived tickets

All ACLI calls are mocked — no real subprocess calls.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading helpers
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"

# Ensure scripts dir is on sys.path so bridge package imports work
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))


def _load_module(filename: str, mod_name: str) -> ModuleType:
    path = SCRIPTS_DIR / filename
    spec = importlib.util.spec_from_file_location(mod_name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def acli() -> ModuleType:
    return _load_module("acli-integration.py", "acli_integration")


@pytest.fixture(scope="module")
def outbound_handlers() -> ModuleType:
    return importlib.import_module("bridge._outbound_handlers")


@pytest.fixture(scope="module")
def inbound() -> ModuleType:
    return _load_module("bridge-inbound.py", "bridge_inbound")


@pytest.fixture(scope="module")
def outbound_api() -> ModuleType:
    return importlib.import_module("bridge._outbound_api")


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_JIRA_KEY = "DSO-42"
_TICKET_ID = "test-0001"
REDUCER_PATH = SCRIPTS_DIR / "ticket-reducer.py"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_sync(ticket_dir: Path, jira_key: str = _JIRA_KEY) -> Path:
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-SYNC.json"
    payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": ticket_dir.name,
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": ts,
    }
    p = ticket_dir / filename
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


def _write_status_event(ticket_dir: Path, status: str) -> Path:
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-STATUS.json"
    payload = {
        "event_type": "STATUS",
        "env_id": "other-env",
        "timestamp": ts,
        "uuid": event_uuid,
        "data": {"status": status},
    }
    p = ticket_dir / filename
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


def _write_create_event(ticket_dir: Path) -> Path:
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-CREATE.json"
    payload = {
        "event_type": "CREATE",
        "env_id": "other-env",
        "timestamp": ts,
        "uuid": event_uuid,
        "data": {"ticket_type": "task", "title": "Test ticket"},
    }
    p = ticket_dir / filename
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


def _make_status_event_dict(ticket_dir: Path, status: str) -> dict:
    """Return a parsed event dict pointing at a real STATUS file on disk."""
    p = _write_status_event(ticket_dir, status)
    return {
        "ticket_id": ticket_dir.name,
        "event_type": "STATUS",
        "file_path": str(p),
    }


# ---------------------------------------------------------------------------
# (a) delete_issue — 200 success path
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_calls_acli_delete(acli: ModuleType) -> None:
    """AcliClient.delete_issue calls 'acli jira workitem delete --key <key>'
    and returns a success dict when ACLI exits 0."""

    client = acli.AcliClient(
        jira_url="https://example.atlassian.net",
        user="u",
        api_token="t",
    )

    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = ""
    mock_result.stderr = ""

    with patch("subprocess.run", return_value=mock_result) as mock_run:
        result = client.delete_issue(_JIRA_KEY)

    # Verify the right ACLI command was assembled
    call_args = mock_run.call_args[0][0]
    assert "delete" in call_args, "ACLI delete subcommand must be present"
    assert _JIRA_KEY in call_args, "Jira key must be passed to ACLI"

    # Result should indicate success
    assert isinstance(result, dict), "delete_issue must return a dict"
    assert result.get("status") == "deleted" or result.get("key") == _JIRA_KEY, (
        "Result must indicate deletion success"
    )


# ---------------------------------------------------------------------------
# (b) delete_issue — 404 treated as idempotent success
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_404_is_idempotent(acli: ModuleType) -> None:
    """When ACLI returns a 404-indicating error, delete_issue treats it as
    success (idempotent) without raising an exception."""

    client = acli.AcliClient(
        jira_url="https://example.atlassian.net",
        user="u",
        api_token="t",
    )

    exc = subprocess.CalledProcessError(
        returncode=1,
        cmd=["acli"],
    )
    exc.stderr = "404 Not Found"
    exc.stdout = ""

    with patch("subprocess.run", side_effect=exc):
        # Must NOT raise — 404 means already deleted
        result = client.delete_issue(_JIRA_KEY)

    assert isinstance(result, dict), "delete_issue must return a dict even on 404"
    assert result.get("status") in ("deleted", "not_found"), (
        "Result must indicate idempotent success"
    )


# ---------------------------------------------------------------------------
# (c) delete_issue — 403 writes BRIDGE_ALERT, no crash
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_403_raises_permission_error(acli: ModuleType) -> None:
    """When ACLI returns a 403 error, delete_issue raises a PermissionError
    so the caller can write a BRIDGE_ALERT and skip deletion.

    (Raising a typed exception is the cleanest contract; caller handles it.)
    """

    client = acli.AcliClient(
        jira_url="https://example.atlassian.net",
        user="u",
        api_token="t",
    )

    exc = subprocess.CalledProcessError(
        returncode=1,
        cmd=["acli"],
    )
    exc.stderr = "403 Forbidden"
    exc.stdout = ""

    with patch("subprocess.run", side_effect=exc):
        with pytest.raises(PermissionError):
            client.delete_issue(_JIRA_KEY)


# ---------------------------------------------------------------------------
# STATUS handler — compiled_status == 'deleted' routes to delete_issue
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_status_handler_deleted_routes_to_delete_issue(
    tmp_path: Path, outbound_handlers: ModuleType
) -> None:
    """When compiled_status is 'deleted', handle_status_event must call
    acli_client.delete_issue(jira_key) instead of update_issue."""

    ticket_dir = tmp_path / _TICKET_ID
    ticket_dir.mkdir()
    _write_sync(ticket_dir)
    event_path = _write_status_event(ticket_dir, "deleted")

    event = {
        "ticket_id": _TICKET_ID,
        "event_type": "STATUS",
        "file_path": str(event_path),
    }

    acli_client = MagicMock()
    acli_client.delete_issue = MagicMock(return_value={"status": "deleted"})
    acli_client.update_issue = MagicMock()

    with patch(
        "bridge._outbound_handlers.get_compiled_status",
        return_value="deleted",
    ):
        outbound_handlers.handle_status_event(
            event,
            acli_client=acli_client,
            tickets_root=tmp_path,
            bridge_env_id=_BRIDGE_ENV_ID,
            run_id="test-run",
            reducer_path=REDUCER_PATH,
            status_updated=set(),
        )

    acli_client.delete_issue.assert_called_once_with(_JIRA_KEY)
    acli_client.update_issue.assert_not_called()


# ---------------------------------------------------------------------------
# STATUS handler — compiled_status == 'deleted', no jira_key → silent skip
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_status_handler_deleted_no_jira_key_skips_silently(
    tmp_path: Path, outbound_handlers: ModuleType
) -> None:
    """When compiled_status is 'deleted' but there is no SYNC file (ticket
    was never pushed to Jira), the handler must skip silently without calling
    delete_issue or update_issue."""

    ticket_dir = tmp_path / "unsynced-0001"
    ticket_dir.mkdir()
    event_path = _write_status_event(ticket_dir, "deleted")

    event = {
        "ticket_id": "unsynced-0001",
        "event_type": "STATUS",
        "file_path": str(event_path),
    }

    acli_client = MagicMock()

    with patch(
        "bridge._outbound_handlers.get_compiled_status",
        return_value="deleted",
    ):
        outbound_handlers.handle_status_event(
            event,
            acli_client=acli_client,
            tickets_root=tmp_path,
            bridge_env_id=_BRIDGE_ENV_ID,
            run_id="test-run",
            reducer_path=REDUCER_PATH,
            status_updated=set(),
        )

    acli_client.delete_issue.assert_not_called()
    acli_client.update_issue.assert_not_called()


# ---------------------------------------------------------------------------
# STATUS handler — 403 on delete writes BRIDGE_ALERT, no crash
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_status_handler_delete_403_writes_bridge_alert(
    tmp_path: Path, outbound_handlers: ModuleType
) -> None:
    """When delete_issue raises PermissionError (403), handle_status_event
    must write a BRIDGE_ALERT and NOT propagate the exception."""

    ticket_dir = tmp_path / _TICKET_ID
    ticket_dir.mkdir()
    _write_sync(ticket_dir)
    event_path = _write_status_event(ticket_dir, "deleted")

    event = {
        "ticket_id": _TICKET_ID,
        "event_type": "STATUS",
        "file_path": str(event_path),
    }

    acli_client = MagicMock()
    acli_client.delete_issue = MagicMock(side_effect=PermissionError("403 Forbidden"))

    with patch(
        "bridge._outbound_handlers.get_compiled_status",
        return_value="deleted",
    ):
        # Must not raise
        outbound_handlers.handle_status_event(
            event,
            acli_client=acli_client,
            tickets_root=tmp_path,
            bridge_env_id=_BRIDGE_ENV_ID,
            run_id="test-run",
            reducer_path=REDUCER_PATH,
            status_updated=set(),
        )

    # A BRIDGE_ALERT file must exist in the ticket dir
    alerts = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alerts) >= 1, "A BRIDGE_ALERT event must be written on 403"

    alert_data = json.loads(alerts[0].read_text())
    assert "403" in alert_data.get("data", {}).get("reason", "") or "403" in str(
        alert_data
    ), "BRIDGE_ALERT reason must mention 403"


# ---------------------------------------------------------------------------
# STATUS handler — 'deleted' intercept is BEFORE generic update_issue call
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_status_handler_deleted_no_transition_attempt(
    tmp_path: Path, outbound_handlers: ModuleType
) -> None:
    """The STATUS handler must ONLY call delete_issue for 'deleted' status.
    It must NOT call update_issue/transition to a 'Deleted' Jira state first."""

    ticket_dir = tmp_path / _TICKET_ID
    ticket_dir.mkdir()
    _write_sync(ticket_dir)
    event_path = _write_status_event(ticket_dir, "deleted")

    event = {
        "ticket_id": _TICKET_ID,
        "event_type": "STATUS",
        "file_path": str(event_path),
    }

    call_order: list[str] = []

    acli_client = MagicMock()
    acli_client.delete_issue = MagicMock(
        side_effect=lambda *a, **kw: (
            call_order.append("delete") or {"status": "deleted"}
        )
    )
    acli_client.update_issue = MagicMock(
        side_effect=lambda *a, **kw: call_order.append("update") or {}
    )

    with patch(
        "bridge._outbound_handlers.get_compiled_status",
        return_value="deleted",
    ):
        outbound_handlers.handle_status_event(
            event,
            acli_client=acli_client,
            tickets_root=tmp_path,
            bridge_env_id=_BRIDGE_ENV_ID,
            run_id="test-run",
            reducer_path=REDUCER_PATH,
            status_updated=set(),
        )

    assert "update" not in call_order, (
        "update_issue must NOT be called for 'deleted' status — only delete_issue"
    )
    assert "delete" in call_order, "delete_issue must be called"


# ---------------------------------------------------------------------------
# (e) Inbound guard: skip events for deleted ticket
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_inbound_guard_skips_deleted_ticket(
    tmp_path: Path, inbound: ModuleType
) -> None:
    """process_inbound must NOT write events for a ticket whose compiled
    local state has status == 'deleted'."""

    ticket_id = "jira-dso-99"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir()
    # Write a STATUS event marking the ticket as deleted locally
    _write_status_event(ticket_dir, "deleted")

    # Fabricate a Jira issue that would normally trigger a CREATE event
    jira_issue = {
        "key": "DSO-99",
        "fields": {
            "summary": "Deleted ticket",
            "issuetype": {"name": "Task"},
            "status": {"name": "To Do"},
            "created": "2024-01-01T00:00:00.000+0000",
            "updated": "2024-01-02T00:00:00.000+0000",
        },
    }

    acli_client = MagicMock()
    acli_client.search_issues = MagicMock(return_value=[jira_issue])
    acli_client.get_myself = MagicMock(return_value={"timeZone": "UTC"})
    acli_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

    with patch(
        "bridge._inbound_api.fetch_jira_changes",
        return_value=[jira_issue],
    ):
        inbound.process_inbound(
            tickets_root=tmp_path,
            acli_client=acli_client,
            last_pull_ts="2024-01-01T00:00:00Z",
            config={
                "bridge_env_id": _BRIDGE_ENV_ID,
                "status_mapping": {"To Do": "open"},
                "type_mapping": {"Task": "task"},
                "run_id": "test-run",
                "checkpoint_file": "",
            },
        )

    # No new CREATE event should have been written
    create_events = list(ticket_dir.glob("*-CREATE.json"))
    assert len(create_events) == 0, (
        "Inbound bridge must NOT write CREATE events for deleted tickets"
    )


# ---------------------------------------------------------------------------
# (e) Inbound guard: skip events for archived ticket
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_inbound_guard_skips_archived_ticket(
    tmp_path: Path, inbound: ModuleType
) -> None:
    """process_inbound must NOT write events for a ticket whose compiled
    local state has archived == True (the ARCHIVED event path in the reducer)."""

    ticket_id = "jira-dso-98"
    ticket_dir = tmp_path / ticket_id
    ticket_dir.mkdir()

    # Write a CREATE event, a STATUS(closed) event, and an ARCHIVED event so the
    # real reducer returns archived=True for this ticket (reducer requires a CREATE
    # event to produce a non-None state).
    _write_create_event(ticket_dir)
    _write_status_event(ticket_dir, "closed")
    archived_ts = time.time_ns()
    archived_uuid = str(uuid.uuid4())
    archived_event_path = ticket_dir / f"{archived_ts}-{archived_uuid}-ARCHIVED.json"
    archived_event_path.write_text(
        json.dumps(
            {
                "event_type": "ARCHIVED",
                "env_id": "test-env",
                "timestamp": archived_ts,
                "uuid": archived_uuid,
                "data": {},
            }
        ),
        encoding="utf-8",
    )

    jira_issue = {
        "key": "DSO-98",
        "fields": {
            "summary": "Archived ticket",
            "issuetype": {"name": "Task"},
            "status": {"name": "Done"},
            "created": "2024-01-01T00:00:00.000+0000",
            "updated": "2024-01-02T00:00:00.000+0000",
        },
    }

    acli_client = MagicMock()
    acli_client.search_issues = MagicMock(return_value=[jira_issue])
    acli_client.get_myself = MagicMock(return_value={"timeZone": "UTC"})
    acli_client.get_server_info = MagicMock(return_value={"timeZone": "UTC"})

    # Helper: non-hidden JSON files only (excludes .cache.json written by the reducer)
    def _event_files(d: Path) -> set[str]:
        return {p.name for p in d.glob("*.json") if not p.name.startswith(".")}

    # Snapshot event file names before process_inbound runs
    names_before = _event_files(ticket_dir)

    with patch(
        "bridge._outbound_api.get_compiled_status",
        side_effect=lambda td, *, reducer_path: (
            "closed" if "jira-dso-98" in str(td) else None
        ),
    ):
        inbound.process_inbound(
            tickets_root=tmp_path,
            acli_client=acli_client,
            last_pull_ts="2024-01-01T00:00:00Z",
            config={
                "bridge_env_id": _BRIDGE_ENV_ID,
                "status_mapping": {"Done": "closed"},
                "type_mapping": {"Task": "task"},
                "run_id": "test-run",
                "checkpoint_file": "",
            },
        )

    # Guard must not have written any new inbound event files
    names_after = _event_files(ticket_dir)
    new_files = names_after - names_before
    assert len(new_files) == 0, (
        f"Inbound bridge must NOT write any new event files for archived tickets, "
        f"but wrote: {sorted(new_files)}"
    )


# ---------------------------------------------------------------------------
# SYNC file survives deletion cycle
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_sync_file_retained_after_deletion(
    tmp_path: Path, outbound_handlers: ModuleType
) -> None:
    """After a successful delete_issue call, the SYNC file must still exist
    so future syncs know not to re-create the Jira issue."""

    ticket_dir = tmp_path / _TICKET_ID
    ticket_dir.mkdir()
    sync_path = _write_sync(ticket_dir)
    event_path = _write_status_event(ticket_dir, "deleted")

    event = {
        "ticket_id": _TICKET_ID,
        "event_type": "STATUS",
        "file_path": str(event_path),
    }

    acli_client = MagicMock()
    acli_client.delete_issue = MagicMock(return_value={"status": "deleted"})

    with patch(
        "bridge._outbound_handlers.get_compiled_status",
        return_value="deleted",
    ):
        outbound_handlers.handle_status_event(
            event,
            acli_client=acli_client,
            tickets_root=tmp_path,
            bridge_env_id=_BRIDGE_ENV_ID,
            run_id="test-run",
            reducer_path=REDUCER_PATH,
            status_updated=set(),
        )

    assert sync_path.exists(), (
        "SYNC file must be retained after delete — prevents future re-creation"
    )
