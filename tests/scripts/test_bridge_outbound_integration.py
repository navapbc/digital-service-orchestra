"""Integration tests for bridge-outbound.py pipeline.

Fixture-based end-to-end tests that exercise process_events() with a
temporary .tickets-tracker directory and mocked ACLI client. No live
Jira or ACLI subprocess calls are made.

Validates:
- SYNC events are written with all contract fields (event_type, jira_key,
  local_id, env_id, timestamp, run_id) per w21-5mr1
- Idempotency: second run writes no additional SYNC events
- Echo prevention: ticket with pre-existing SYNC event is skipped

Integration exemption: not RED-first; written after implementation per
integration test task rule.
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
    """Return the bridge-outbound module."""
    if not SCRIPT_PATH.exists():
        pytest.fail(f"bridge-outbound.py not found at {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_RUN_ID = "9876543210"
_FIXTURE_UUID = "aaaa1111-2222-3333-4444-555566667777"

# SYNC contract fields (w21-5mr1)
_SYNC_REQUIRED_FIELDS = {
    "event_type",
    "jira_key",
    "local_id",
    "env_id",
    "timestamp",
    "run_id",
}


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _setup_ticket_with_create(
    tracker_dir: Path,
    ticket_id: str,
    *,
    env_id: str = _OTHER_ENV_ID,
    title: str = "Test ticket",
) -> Path:
    """Create a ticket directory with a CREATE event file.

    Uses epoch-uuid-uppercase filename convention matching the _EVENT_FILE_RE
    pattern in bridge-outbound.py and lexicographic sort requirement of
    ticket-reducer.py. Format: <epoch>-<uuid>-<EVENT_TYPE>.json

    Returns the ticket directory path.
    """
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    create_payload = {
        "event_type": "CREATE",
        "uuid": _FIXTURE_UUID,
        "timestamp": 1742605200,
        "author": "integration-test",
        "env_id": env_id,
        "data": {
            "ticket_type": "task",
            "title": title,
        },
    }
    # Epoch-uuid-uppercase filename matching _EVENT_FILE_RE in bridge-outbound.py:
    # <timestamp>-<uuid>-<EVENT_TYPE>.json
    create_file = ticket_dir / f"1742605200-{_FIXTURE_UUID}-CREATE.json"
    create_file.write_text(json.dumps(create_payload))
    return ticket_dir


def _build_git_diff_output(tracker_dir: Path, ticket_id: str) -> str:
    """Build git diff --name-only style output for a ticket's CREATE event.

    The path format must match the _EVENT_FILE_RE regex in bridge-outbound.py:
    .tickets-tracker/<ticket-id>/<timestamp>-<uuid>-<EVENT_TYPE>.json

    Paths are relative to tracker_dir.parent (the repo root equivalent).
    Tests must set CWD to tracker_dir.parent (via monkeypatch.chdir) so that
    _read_event_file() in bridge-outbound.py can resolve these relative paths
    to the actual fixture files created under tmp_path.
    """
    return f".tickets-tracker/{ticket_id}/1742605200-{_FIXTURE_UUID}-CREATE.json\n"


def _make_mock_acli(jira_key: str = "DSO-42") -> MagicMock:
    """Create a mock ACLI client that returns a predictable Jira key."""
    mock = MagicMock()
    mock.create_issue = MagicMock(return_value={"key": jira_key})
    mock.update_issue = MagicMock(return_value={"key": jira_key})
    mock.get_issue = MagicMock(return_value={"key": jira_key})
    return mock


def _write_env_id_file(tracker_dir: Path, env_id: str) -> None:
    """Write .env-id file in the tracker directory."""
    env_id_file = tracker_dir / ".env-id"
    env_id_file.write_text(env_id)


# ---------------------------------------------------------------------------
# Test: SYNC event has all contract fields
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_sync_event_fields(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """process_events() writes a SYNC event containing all fields from the
    SYNC contract (w21-5mr1): event_type, jira_key, local_id, env_id,
    timestamp, run_id.

    Uses epoch-uuid-uppercase fixture filenames matching _EVENT_FILE_RE in
    bridge-outbound.py and ticket-reducer.py's lexicographic sort requirement.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    # CWD must be tmp_path so that relative paths in git_diff_output
    # (e.g. .tickets-tracker/<id>/...) resolve to fixture files under tmp_path.
    monkeypatch.chdir(tmp_path)
    _write_env_id_file(tracker_dir, _BRIDGE_ENV_ID)

    ticket_id = "w21-integ1"
    jira_key = "DSO-42"
    _setup_ticket_with_create(tracker_dir, ticket_id)

    mock_acli = _make_mock_acli(jira_key=jira_key)
    git_diff = _build_git_diff_output(tracker_dir, ticket_id)

    syncs = bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        git_diff_output=git_diff,
        bridge_env_id=_BRIDGE_ENV_ID,
        run_id=_RUN_ID,
    )

    # process_events returns list of SYNC dicts
    assert len(syncs) == 1, f"Expected 1 SYNC event written, got {len(syncs)}"
    sync_result = syncs[0]
    assert sync_result["jira_key"] == jira_key
    assert sync_result["local_id"] == ticket_id

    # Verify the SYNC event file on disk has all contract fields
    ticket_dir = tracker_dir / ticket_id
    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    assert len(sync_files) == 1, f"Expected 1 SYNC file on disk, got {len(sync_files)}"

    sync_data = json.loads(sync_files[0].read_text())

    # All fields from the SYNC contract must be present
    missing = _SYNC_REQUIRED_FIELDS - set(sync_data.keys())
    assert not missing, f"SYNC event missing contract fields: {missing}"

    # Verify field values
    assert sync_data["event_type"] == "SYNC"
    assert sync_data["jira_key"] == jira_key
    assert sync_data["local_id"] == ticket_id
    assert sync_data["env_id"] == _BRIDGE_ENV_ID
    assert isinstance(sync_data["timestamp"], int)
    assert sync_data["run_id"] == _RUN_ID


# ---------------------------------------------------------------------------
# Test: Idempotency — second run writes no additional SYNC events
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_idempotent_second_run(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Running process_events() twice on the same ticket produces only one
    SYNC event file. The second run detects the existing SYNC and skips.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    # CWD must be tmp_path so that relative paths in git_diff_output resolve
    # to fixture files under tmp_path.
    monkeypatch.chdir(tmp_path)
    _write_env_id_file(tracker_dir, _BRIDGE_ENV_ID)

    ticket_id = "w21-idemp1"
    jira_key = "DSO-55"
    _setup_ticket_with_create(tracker_dir, ticket_id)

    mock_acli = _make_mock_acli(jira_key=jira_key)
    git_diff = _build_git_diff_output(tracker_dir, ticket_id)

    # First run — should create a SYNC event
    syncs_1 = bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        git_diff_output=git_diff,
        bridge_env_id=_BRIDGE_ENV_ID,
        run_id=_RUN_ID,
    )
    assert len(syncs_1) == 1, "First run must write exactly 1 SYNC event"

    ticket_dir = tracker_dir / ticket_id
    sync_count_after_first = len(list(ticket_dir.glob("*-SYNC.json")))
    assert sync_count_after_first == 1

    # Second run — should NOT create another SYNC event
    syncs_2 = bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        git_diff_output=git_diff,
        bridge_env_id=_BRIDGE_ENV_ID,
        run_id=_RUN_ID,
    )
    assert len(syncs_2) == 0, "Second run must write 0 SYNC events (idempotent)"

    sync_count_after_second = len(list(ticket_dir.glob("*-SYNC.json")))
    assert sync_count_after_second == 1, (
        f"SYNC file count must remain 1 after second run, got {sync_count_after_second}"
    )

    # create_issue should only have been called once (from the first run)
    assert mock_acli.create_issue.call_count == 1


# ---------------------------------------------------------------------------
# Test: Echo prevention — pre-existing SYNC skips CREATE processing
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_echo_prevention_preexisting_sync(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A ticket with a pre-existing SYNC event (e.g., from inbound import)
    is skipped entirely — no create_issue call and no additional SYNC written.
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    # CWD must be tmp_path so that relative paths in git_diff_output resolve
    # to fixture files under tmp_path.
    monkeypatch.chdir(tmp_path)
    _write_env_id_file(tracker_dir, _BRIDGE_ENV_ID)

    ticket_id = "w21-echo1"
    ticket_dir = _setup_ticket_with_create(tracker_dir, ticket_id)

    # Write a pre-existing SYNC event (simulates inbound import)
    # Uses timestamp-based filename convention
    preexisting_sync = {
        "event_type": "SYNC",
        "jira_key": "DSO-99",
        "local_id": ticket_id,
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742605100,
        "run_id": "1111111111",
    }
    sync_file = ticket_dir / "1742605100-deadbeef-dead-beef-dead-beefdeadbeef-SYNC.json"
    sync_file.write_text(json.dumps(preexisting_sync))

    mock_acli = _make_mock_acli(jira_key="DSO-99")
    git_diff = _build_git_diff_output(tracker_dir, ticket_id)

    syncs = bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        git_diff_output=git_diff,
        bridge_env_id=_BRIDGE_ENV_ID,
        run_id=_RUN_ID,
    )

    # No new SYNC events should be written
    assert len(syncs) == 0, "Echo prevention: no SYNC events should be written"

    # create_issue must not be called
    mock_acli.create_issue.assert_not_called()

    # Only the pre-existing SYNC file should exist
    sync_files = list(ticket_dir.glob("*-SYNC.json"))
    assert len(sync_files) == 1, (
        f"Only pre-existing SYNC file should exist, got {len(sync_files)}"
    )


# ---------------------------------------------------------------------------
# Test: End-to-end with multiple tickets
# ---------------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.scripts
def test_end_to_end_multiple_tickets(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """process_events() handles multiple tickets in a single run:
    - Ticket A: new CREATE, no prior SYNC -> creates issue + writes SYNC
    - Ticket B: CREATE with pre-existing SYNC -> skipped (echo prevention)
    """
    tracker_dir = tmp_path / ".tickets-tracker"
    tracker_dir.mkdir()
    # CWD must be tmp_path so that relative paths in git_diff_output resolve
    # to fixture files under tmp_path.
    monkeypatch.chdir(tmp_path)
    _write_env_id_file(tracker_dir, _BRIDGE_ENV_ID)

    # Ticket A: fresh ticket, should be processed
    ticket_a_id = "w21-multi1"
    _setup_ticket_with_create(tracker_dir, ticket_a_id, title="Fresh ticket")

    # Ticket B: already has SYNC, should be skipped
    ticket_b_id = "w21-multi2"
    ticket_b_dir = _setup_ticket_with_create(
        tracker_dir, ticket_b_id, title="Already synced"
    )
    preexisting_sync = {
        "event_type": "SYNC",
        "jira_key": "DSO-88",
        "local_id": ticket_b_id,
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": 1742605000,
        "run_id": "0000000000",
    }
    sync_file = (
        ticket_b_dir / "1742605000-cccccccc-0000-4000-8000-000000000003-SYNC.json"
    )
    sync_file.write_text(json.dumps(preexisting_sync))

    mock_acli = _make_mock_acli(jira_key="DSO-101")

    # Build git diff with both tickets
    git_diff = (
        f".tickets-tracker/{ticket_a_id}/1742605200-{_FIXTURE_UUID}-CREATE.json\n"
        f".tickets-tracker/{ticket_b_id}/1742605200-{_FIXTURE_UUID}-CREATE.json\n"
    )

    syncs = bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        git_diff_output=git_diff,
        bridge_env_id=_BRIDGE_ENV_ID,
        run_id=_RUN_ID,
    )

    # Only ticket A should produce a SYNC event
    assert len(syncs) == 1, f"Expected 1 SYNC event (ticket A only), got {len(syncs)}"
    assert syncs[0]["local_id"] == ticket_a_id

    # create_issue called once (for ticket A only)
    assert mock_acli.create_issue.call_count == 1

    # Ticket A should have 1 SYNC file
    sync_files_a = list((tracker_dir / ticket_a_id).glob("*-SYNC.json"))
    assert len(sync_files_a) == 1

    # Ticket B should still have only its pre-existing SYNC file
    sync_files_b = list((tracker_dir / ticket_b_id).glob("*-SYNC.json"))
    assert len(sync_files_b) == 1
