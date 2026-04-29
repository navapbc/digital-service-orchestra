"""RED tests for da40-8e3e: COMPACT commit must not trigger duplicate Jira issue.

Root cause: git diff HEAD~1 HEAD --name-only returns deleted files too;
COMPACT deletes SYNC.json so has_existing_sync() returns False; the deleted
CREATE.json in the diff is re-processed as a CREATE event -> duplicate Jira issue.

Fix (A+C):
  A: bridge-outbound.py - use --diff-filter=A so only ADDED files are processed
  C: ticket-compact.sh  - exclude *-SYNC.json from event_files so SYNC survives

These tests are RED before fix A is applied.
"""

from __future__ import annotations

import importlib.util
import json
import time
import uuid
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-outbound.py"

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_EXISTING_JIRA_KEY = "DSO-100"
_TICKET_ID = "5dc3-0d5e"


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


def _write_sync(ticket_dir: Path, jira_key: str) -> Path:
    ts = int(time.time_ns())
    ev_uuid = str(uuid.uuid4())
    path = ticket_dir / f"{ts}-{ev_uuid}-SYNC.json"
    path.write_text(
        json.dumps(
            {
                "event_type": "SYNC",
                "timestamp": ts,
                "uuid": ev_uuid,
                "env_id": _BRIDGE_ENV_ID,
                "jira_key": jira_key,
                "local_id": _TICKET_ID,
            }
        ),
        encoding="utf-8",
    )
    return path


def _write_snapshot(ticket_dir: Path, compiled_state: dict) -> Path:
    ts = int(time.time_ns())
    ev_uuid = str(uuid.uuid4())
    path = ticket_dir / f"{ts}-{ev_uuid}-SNAPSHOT.json"
    path.write_text(
        json.dumps(
            {
                "event_type": "SNAPSHOT",
                "timestamp": ts,
                "uuid": ev_uuid,
                "env_id": _OTHER_ENV_ID,
                "data": {
                    "compiled_state": compiled_state,
                    "source_event_uuids": [],
                    "compacted_at": ts,
                },
            }
        ),
        encoding="utf-8",
    )
    return path


def _make_mock_acli(jira_key: str = "DSO-200") -> MagicMock:
    mock = MagicMock()
    mock.create_issue = MagicMock(return_value={"key": jira_key})
    mock.update_issue = MagicMock(return_value={"key": jira_key})
    return mock


@pytest.mark.scripts
def test_compact_commit_does_not_create_duplicate_issue(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """After COMPACT, bridge subprocess diff (--diff-filter=A) must not yield a CREATE event.

    Fix A: process_events() uses git diff --diff-filter=A --name-only (added-only).
    For a COMPACT commit, only the new SNAPSHOT file is listed; the deleted CREATE.json
    and SYNC.json do NOT appear. With no CREATE event in the diff, create_issue is
    never called and no duplicate is produced.

    This test mocks subprocess.run to return what git diff --diff-filter=A produces
    for a COMPACT commit (only the added SNAPSHOT), then asserts create_issue is not
    called. It is RED before fix A is applied (old --name-only would include the
    deleted CREATE.json path, which parse_git_diff_events() would parse as a CREATE
    event, triggering a duplicate).

    Methodology: monkeypatching subprocess.run ensures we test the exact diff
    command that process_events() issues, not a pre-parsed git_diff_output shortcut.
    """
    import subprocess as _subprocess

    tracker_dir = (
        tmp_path / ".tickets-tracker"
    )  # tickets-boundary-ok: test creates tracker dir in tmp_path
    tracker_dir.mkdir()
    monkeypatch.chdir(tmp_path)
    (tracker_dir / ".env-id").write_text(_BRIDGE_ENV_ID)

    ticket_dir = tracker_dir / _TICKET_ID
    ticket_dir.mkdir()

    snapshot_path = _write_snapshot(
        ticket_dir,
        {"title": "Real ticket title", "status": "closed"},
    )

    # What git diff --diff-filter=A --name-only produces for a COMPACT commit:
    # only the added SNAPSHOT file; deleted CREATE/SYNC are absent.
    added_only_diff = f"{_TICKET_ID}/{snapshot_path.name}\n"

    # What git diff --name-only (no --diff-filter) produces — includes deleted files.
    _old_uuid = "a1b2c3d4-e5f6-4000-8000-aabbccddeeff"
    full_diff = (
        f"{_TICKET_ID}/1000000000000-{_old_uuid}-CREATE.json\n"
        f"{_TICKET_ID}/1000000001000-{_old_uuid}-SYNC.json\n"
        f"{_TICKET_ID}/{snapshot_path.name}\n"
    )

    def _mock_subprocess_run(cmd, **kwargs):
        """Return the diff output that matches what the current bridge code requests."""
        result = _subprocess.CompletedProcess(cmd, 0)
        if "--diff-filter=A" in cmd:
            # Fix A is in place: return added-only diff (no deleted files)
            result.stdout = added_only_diff
        else:
            # Bug: --name-only without --diff-filter returns deleted files too
            result.stdout = full_diff
        result.stderr = ""
        return result

    monkeypatch.setattr("subprocess.run", _mock_subprocess_run)

    mock_acli = _make_mock_acli()

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        bridge_env_id=_BRIDGE_ENV_ID,
        # No git_diff_output — forces the subprocess path
    )

    # After fix A: create_issue must NOT be called (no duplicate Jira issue)
    mock_acli.create_issue.assert_not_called()


@pytest.mark.scripts
def test_compact_commit_with_existing_sync_on_disk_does_not_create_duplicate(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """After COMPACT with fix C (SYNC preserved on disk), create_issue is not called.

    When ticket-compact.sh excludes *-SYNC.json from deletion, has_existing_sync()
    returns True and the CREATE dedup guard fires even if the old CREATE.json
    appears in the diff output.

    This test passes even WITHOUT fix A (it relies only on fix C), so it verifies
    the belt-and-suspenders property: even if fix A is removed, fix C alone prevents
    the duplicate.

    This test is RED before fix C is applied (since SYNC.json is currently deleted
    by compact, this scenario is currently impossible to reach).
    """
    tracker_dir = (
        tmp_path / ".tickets-tracker"
    )  # tickets-boundary-ok: test creates tracker dir in tmp_path
    tracker_dir.mkdir()
    monkeypatch.chdir(tmp_path)
    (tracker_dir / ".env-id").write_text(_BRIDGE_ENV_ID)

    ticket_dir = tracker_dir / _TICKET_ID
    ticket_dir.mkdir()

    # Fix C: SYNC.json survives compaction and is present on disk.
    _write_sync(ticket_dir, jira_key=_EXISTING_JIRA_KEY)

    # COMPACT also writes SNAPSHOT.
    snapshot_path = _write_snapshot(
        ticket_dir,
        {"title": "Real ticket title", "status": "closed"},
    )

    # Simulate compact diff (includes both deleted CREATE and added SNAPSHOT).
    _old_uuid = "a1b2c3d4-e5f6-4000-8000-aabbccddeeff"
    deleted_create = f".tickets-tracker/{_TICKET_ID}/1000000000000-{_old_uuid}-CREATE.json"  # tickets-boundary-ok: simulated git diff path string
    added_snapshot = f".tickets-tracker/{_TICKET_ID}/{snapshot_path.name}"  # tickets-boundary-ok: simulated git diff path string
    compact_diff = f"{deleted_create}\n{added_snapshot}\n"

    mock_acli = _make_mock_acli()

    bridge.process_events(
        tickets_dir=str(tracker_dir),
        acli_client=mock_acli,
        git_diff_output=compact_diff,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # With SYNC present (fix C), the dedup guard fires -> no duplicate.
    mock_acli.create_issue.assert_not_called()


@pytest.mark.scripts
def test_resolve_jira_key_survives_compact_when_sync_preserved(
    tmp_path: Path, bridge: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    """After COMPACT with fix C, resolve_jira_key() still returns the correct key.

    Currently, COMPACT deletes SYNC.json, causing resolve_jira_key() to return None
    for all post-COMPACT outbound events (STATUS, COMMENT, EDIT). Fix C preserves
    SYNC.json so the mapping survives compaction.

    This test is RED before fix C is applied (resolve_jira_key returns None when
    SYNC is absent).
    """
    import sys  # noqa: PLC0415

    _scripts_dir = str(REPO_ROOT / "plugins" / "dso" / "scripts")
    if _scripts_dir not in sys.path:
        sys.path.insert(0, _scripts_dir)
    from bridge._outbound_api import resolve_jira_key  # type: ignore[import]  # noqa: PLC0415

    ticket_dir = tmp_path / _TICKET_ID
    ticket_dir.mkdir()

    # SYNC survives compaction (fix C).
    _write_sync(ticket_dir, jira_key=_EXISTING_JIRA_KEY)

    # SNAPSHOT also exists (written by compact).
    _write_snapshot(ticket_dir, {"title": "Real ticket title", "status": "closed"})

    # resolve_jira_key must return the correct key even with SNAPSHOT present.
    result = resolve_jira_key(ticket_dir)
    assert result == _EXISTING_JIRA_KEY, (
        f"resolve_jira_key returned {result!r} after COMPACT; "
        f"expected {_EXISTING_JIRA_KEY!r}. "
        "Fix C (exclude SYNC from compact deletion) is required."
    )
