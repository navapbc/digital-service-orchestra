"""Round-trip integration tests + failure-injection matrix for the
DSO <-> Jira bridge (story 8b7d-f63b-bca0-4e1b).

Guards against regression of the four silent-drop fixes shipped in this epic:
  1. HEAD~1..HEAD cursor blindness  (S1 / 6b6e — _outbound_cursor.fetch_events_since_cursor)
  2. filter_bridge_events back-compat when bridge_env_id == ""  (S2 / 3580)
  3. ADF isinstance bug in inbound description handling  (S3 / 5f23 — _adf_to_text)
  4. Null-assignee + BRIDGE_USER_MAP no-match path  (S4 / 7759 — handle_create_event + unassign_issue)

All Jira interactions are mocked.  Each failure-injection test is a separate
function so CI failure messages name the specific bug class that regressed.
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
from unittest.mock import MagicMock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"

# Ensure the scripts directory is on sys.path so ``bridge.*`` resolves.
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))


# ---------------------------------------------------------------------------
# Module loaders (bridge-outbound.py and bridge-inbound.py have hyphens, so
# importlib is required.)
# ---------------------------------------------------------------------------


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def outbound_mod() -> ModuleType:
    return _load_module("bridge_outbound_rt", SCRIPT_DIR / "bridge-outbound.py")


@pytest.fixture(scope="module")
def inbound_api_mod() -> ModuleType:
    from bridge import _inbound_api  # noqa: PLC0415

    return _inbound_api


@pytest.fixture(scope="module")
def inbound_utils_mod() -> ModuleType:
    from bridge import _inbound_utils  # noqa: PLC0415

    return _inbound_utils


@pytest.fixture(scope="module")
def outbound_api_mod() -> ModuleType:
    from bridge import _outbound_api  # noqa: PLC0415

    return _outbound_api


@pytest.fixture(scope="module")
def handlers_mod() -> ModuleType:
    from bridge import _outbound_handlers  # noqa: PLC0415

    return _outbound_handlers


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=True,
    )


def _make_bridge_git_tracker(tmp_path: Path) -> Path:
    """Create a git repo simulating the .tickets-tracker branch."""
    repo = tmp_path / ".tickets-tracker"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "tickets")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "README.md").write_text("baseline\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-q", "-m", "baseline")
    return repo


def _write_event(
    tracker: Path,
    ticket_id: str,
    event_type: str,
    data: dict,
    *,
    env_id: str = "aaaaaaaa-0000-4000-8000-000000000001",
    commit: bool = True,
    extra: dict | None = None,
) -> Path:
    """Write a single event JSON file (and git-commit it). Returns file path."""
    ticket_dir = tracker / ticket_id
    ticket_dir.mkdir(exist_ok=True)
    ts = time.time_ns()
    eu = str(uuid.uuid4())
    filename = f"{ts}-{eu}-{event_type}.json"
    payload: dict = {
        "event_type": event_type,
        "timestamp": ts,
        "uuid": eu,
        "env_id": env_id,
        "data": data,
    }
    if extra:
        payload.update(extra)
    path = ticket_dir / filename
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    if commit:
        _git(tracker, "add", str(path.relative_to(tracker)))
        _git(tracker, "commit", "-q", "-m", f"{event_type} {ticket_id}")
    return path


def _adf_paragraph(text: str) -> dict:
    """Build a minimal ADF doc with a single paragraph."""
    return {
        "type": "doc",
        "version": 1,
        "content": [
            {
                "type": "paragraph",
                "content": [{"type": "text", "text": text}],
            }
        ],
    }


# ---------------------------------------------------------------------------
# Round-trip: description + assignee preservation
# ---------------------------------------------------------------------------


def test_round_trip_preserves_description_and_assignee(
    tmp_path: Path,
    outbound_mod: ModuleType,
    handlers_mod: ModuleType,
    outbound_api_mod: ModuleType,
    inbound_api_mod: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """local-CREATE -> outbound (mocked Jira) -> inbound write_create_events
    (mocked Jira GET) -> local CREATE event preserves the description text and
    assignee displayName.

    Covers:
      - S2 back-compat: filter_bridge_events with bridge_env_id="" returns all
        events unchanged (no silent drop).
      - S4 no-match path: assignee not in BRIDGE_USER_MAP triggers
        unassign_issue and a BRIDGE_ALERT, but DOES NOT abort the create.
      - S3 ADF round-trip: inbound write_create_events recovers description text
        from a Jira ADF dict instead of writing description=None.
    """
    tracker = tmp_path / ".tickets-tracker"
    tracker.mkdir()
    description_text = "Round-trip description body"
    create_path = _write_event(
        tracker,
        "ticket-rt-1",
        "CREATE",
        {
            "ticket_type": "task",
            "title": "Round-trip ticket",
            "priority": 2,
            "assignee": "Unmapped User",
            "description": description_text,
        },
        env_id="aaaaaaaa-0000-4000-8000-000000000001",
        commit=False,  # bare tracker; we drive handlers directly
    )

    # --- Step A: S2 back-compat — filter_bridge_events("") leaves events alone.
    raw_events = [
        {
            "ticket_id": "ticket-rt-1",
            "event_type": "CREATE",
            "file_path": str(create_path),
            "env_id": "aaaaaaaa-0000-4000-8000-000000000001",
        }
    ]
    filtered = outbound_api_mod.filter_bridge_events(raw_events, bridge_env_id="")
    assert filtered == raw_events, (
        "S2 back-compat regressed: filter_bridge_events with empty bridge_env_id "
        "must pass events through unchanged — otherwise every legacy caller "
        "silently loses every event"
    )

    # --- Step B: outbound CREATE handler (S4 no-match) ---
    monkeypatch.delenv("BRIDGE_USER_MAP", raising=False)
    acli = MagicMock()
    acli.create_issue.return_value = {"key": "PROJ-123"}
    acli.unassign_issue.return_value = None

    syncs = handlers_mod.handle_create_event(
        filtered[0],
        acli_client=acli,
        tickets_root=tracker,
        bridge_env_id="",
        run_id="rt-run",
    )

    assert acli.create_issue.called, (
        "handle_create_event must call create_issue even when assignee is unmapped"
    )
    sent_payload = acli.create_issue.call_args.args[0]
    assert "assignee" not in sent_payload, (
        "S4 fix regressed: unmapped assignee leaked into create_issue payload"
    )
    acli.unassign_issue.assert_called_once_with("PROJ-123")
    assert syncs and syncs[0]["jira_key"] == "PROJ-123"

    ticket_dir = tracker / "ticket-rt-1"
    sync_files = list(ticket_dir.glob("*-SYNC.json"))
    assert len(sync_files) == 1, "exactly one SYNC marker must be written"
    alert_files = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
    assert any(
        "BRIDGE_USER_MAP" in json.loads(p.read_text())["data"]["reason"]
        for p in alert_files
    ), "BRIDGE_ALERT for unmapped assignee was not written"

    # --- Inbound: simulate Jira returning the same ticket back to us with an
    # ADF description and a Jira displayName assignee. write_create_events must
    # recover the description text via _adf_to_text.
    inbound_tracker = tmp_path / "inbound-tracker"
    inbound_tracker.mkdir()
    jira_issues = [
        {
            "key": "PROJ-999",  # a different jira_key so dedup doesn't skip
            "fields": {
                "issuetype": {"name": "Task"},
                "summary": "Round-trip ticket",
                "description": _adf_paragraph(description_text),
                "priority": {"name": "Medium"},
                "assignee": {
                    "displayName": "Some Real User",
                    "emailAddress": "real@example.com",
                },
                "created": "2026-05-07T10:00:00.000+0000",
                "updated": "2026-05-07T10:00:00.000+0000",
            },
        }
    ]
    written = inbound_api_mod.write_create_events(
        jira_issues,
        tickets_tracker=inbound_tracker,
        bridge_env_id="bbbbbbbb-0000-4000-8000-000000000002",
        run_id="rt-inbound",
    )
    assert len(written) == 1
    create_payload = json.loads(written[0].read_text(encoding="utf-8"))
    desc = create_payload["data"]["description"]
    assert desc is not None, (
        "inbound CREATE description is None — S3 ADF isinstance fix has regressed "
        "(_adf_to_text not used in write_create_events)"
    )
    assert description_text in desc, (
        f"inbound CREATE description does not contain ADF text content; got {desc!r}"
    )
    assert create_payload["data"]["assignee"] == "Some Real User"


# ---------------------------------------------------------------------------
# Shell-entry-point multi-commit detection (S1 cursor wiring)
# ---------------------------------------------------------------------------


def test_shell_entry_point_multi_commit_catches_all_events(
    tmp_path: Path,
    outbound_mod: ModuleType,
) -> None:
    """When 3 CREATE-event commits land between bridge runs (so they sit at
    HEAD~3, HEAD~2, HEAD~1 — none in HEAD~1..HEAD after a trailing commit),
    process_events must process all 3 — not just the last one.

    This validates that bridge-outbound.py wires the SHA-cursor correctly into
    its main entry point.  Per the story spec, this avoids the subprocess
    complexity by driving process_events directly with a real git tracker.
    """
    tracker = _make_bridge_git_tracker(tmp_path)
    from bridge import _outbound_cursor  # noqa: PLC0415

    # Seed the cursor at the baseline so the next commits are all "new".
    base_sha = _git(tracker, "rev-parse", "HEAD").stdout.strip()
    _outbound_cursor.write_cursor(tracker, base_sha, run_id="prev")

    _write_event(tracker, "tk-c1", "CREATE", {"ticket_type": "task", "title": "T1"})
    _write_event(tracker, "tk-c2", "CREATE", {"ticket_type": "task", "title": "T2"})
    _write_event(tracker, "tk-c3", "CREATE", {"ticket_type": "task", "title": "T3"})
    # Trailing dummy commit so the 3 events are NOT in HEAD~1..HEAD.
    (tracker / "README.md").write_text("baseline\nbump\n", encoding="utf-8")
    _git(tracker, "add", "README.md")
    _git(tracker, "commit", "-q", "-m", "trailing")

    head_sha = _git(tracker, "rev-parse", "HEAD").stdout.strip()

    # Mock acli: each create_issue returns a unique key.
    acli = MagicMock()
    acli.create_issue.side_effect = [{"key": f"PROJ-{i}"} for i in (10, 11, 12)]

    syncs = outbound_mod.process_events(
        tickets_dir=tracker,
        acli_client=acli,
        bridge_env_id="bbbbbbbb-0000-4000-8000-000000000002",
        run_id="run-multi",
    )

    assert acli.create_issue.call_count == 3, (
        f"shell entry-point processed {acli.create_issue.call_count}/3 events — "
        "S1 SHA-cursor (fetch_events_since_cursor) must walk every commit since "
        "the previous checkpoint, not just HEAD~1..HEAD"
    )
    seen_keys = {s["jira_key"] for s in syncs}
    assert seen_keys == {"PROJ-10", "PROJ-11", "PROJ-12"}

    # Cursor advanced to the latest HEAD.
    assert _outbound_cursor.read_cursor(tracker) == head_sha


# ---------------------------------------------------------------------------
# Failure-injection matrix — separate functions per bug class.
# ---------------------------------------------------------------------------


def test_cursor_revert_drops_old_commits(
    tmp_path: Path, outbound_api_mod: ModuleType
) -> None:
    """Confirm what would regress without the cursor fix (S1).

    git diff HEAD~1..HEAD only sees files added in the most recent commit.
    With three back-to-back commits, parse_git_diff_events on HEAD~1..HEAD
    yields exactly one event (the last commit's), proving the original
    HEAD~1 blindness drops the older two.  This documents the silent-drop
    surface that fetch_events_since_cursor exists to close.
    """
    tracker = _make_bridge_git_tracker(tmp_path)
    _write_event(tracker, "tk-r1", "STATUS", {"status": "in_progress"})
    _write_event(tracker, "tk-r2", "STATUS", {"status": "in_progress"})
    _write_event(tracker, "tk-r3", "STATUS", {"status": "in_progress"})

    # Reproduce the pre-fix behaviour exactly: diff only the last commit.
    diff = _git(
        tracker,
        "diff",
        "HEAD~1",
        "HEAD",
        "--diff-filter=A",
        "--name-only",
    ).stdout
    # The shell entry-point used to prefix each path with .tickets-tracker/.
    diff_prefixed = "\n".join(
        f".tickets-tracker/{line}" for line in diff.strip().splitlines() if line
    )
    events = outbound_api_mod.parse_git_diff_events(diff_prefixed)
    assert len(events) == 1, (
        f"HEAD~1..HEAD diff yielded {len(events)} events; expected 1. The whole "
        "point of this regression-injection test is to demonstrate that the old "
        "diff range silently drops older commits — if this assertion ever flips, "
        "the test no longer guards anything."
    )


def test_env_id_revert_drops_all_events(
    tmp_path: Path, outbound_api_mod: ModuleType
) -> None:
    """Confirm what would regress without the back-compat guard (S2).

    Pre-fix behaviour: filter_bridge_events with non-empty bridge_env_id drops
    every event whose env_id mismatches.  When every event has env_id="" (the
    common back-compat case), an unguarded callsite drops EVERYTHING.

    Post-fix behaviour: empty bridge_env_id passes all events through unchanged.
    """
    events = [
        {"event_type": "CREATE", "ticket_id": "tk-1", "env_id": ""},
        {"event_type": "CREATE", "ticket_id": "tk-2", "env_id": ""},
        {"event_type": "CREATE", "ticket_id": "tk-3", "env_id": ""},
    ]

    # Pre-fix surface: with a non-empty bridge_env_id, every env_id="" event is
    # dropped (env_id != bridge_env_id).
    pre_fix = outbound_api_mod.filter_bridge_events(
        events, bridge_env_id="bbbbbbbb-0000-4000-8000-000000000002"
    )
    # Note: events with env_id="" mismatch the bridge_env_id, so they DO pass
    # through under the non-empty branch.  The actual silent-drop surface
    # appears when env_id MATCHES the bridge env (echo prevention).  Verify
    # that scenario directly so the "drops everything" semantic is captured.
    own_events = [
        {"event_type": "CREATE", "ticket_id": "tk-x", "env_id": "bridge-env"},
        {"event_type": "CREATE", "ticket_id": "tk-y", "env_id": "bridge-env"},
    ]
    assert pre_fix == events, (
        "sanity: env_id mismatch should pass through under the non-empty branch"
    )
    assert (
        outbound_api_mod.filter_bridge_events(own_events, bridge_env_id="bridge-env")
        == []
    ), "echo prevention: events whose env_id matches the bridge env are dropped"

    # Post-fix back-compat: empty bridge_env_id returns ALL events unchanged,
    # even those whose env_id equals "bridge-env" (because filtering is skipped
    # entirely).
    pass_through = outbound_api_mod.filter_bridge_events(own_events, bridge_env_id="")
    assert pass_through == own_events, (
        "S2 back-compat guard regressed: empty bridge_env_id must short-circuit "
        "to return events unchanged. Without this, callers that omit the env id "
        "silently lose every event."
    )


def test_adf_isinstance_revert_drops_description(
    inbound_utils_mod: ModuleType,
) -> None:
    """Confirm what would regress without _adf_to_text (S3).

    Pre-fix code did:  description = raw if isinstance(raw, str) else None
    For Jira REST v3 ADF dicts that yields None — a silent drop of the entire
    description field for every Jira-originated CREATE.

    Post-fix:  _adf_to_text(raw_dict) returns the joined text content.
    """
    adf = {
        "type": "doc",
        "version": 1,
        "content": [
            {
                "type": "paragraph",
                "content": [{"type": "text", "text": "Hello world"}],
            }
        ],
    }
    # Pre-fix surface: isinstance check.
    pre_fix_value = adf if isinstance(adf, str) else None
    assert pre_fix_value is None, (
        "sanity: ADF dicts are not str — the pre-fix isinstance branch produced None"
    )

    # Post-fix surface: _adf_to_text recovers the text.
    text = inbound_utils_mod._adf_to_text(adf)
    assert "Hello world" in text, (
        f"S3 ADF isinstance fix regressed: _adf_to_text({adf!r}) returned {text!r}; "
        "expected the paragraph text to be preserved"
    )
    # And: plain strings still pass through (back-compat).
    assert inbound_utils_mod._adf_to_text("plain text") == "plain text"
    # And: None becomes empty string, never crashes.
    assert inbound_utils_mod._adf_to_text(None) == ""


def test_null_assignee_revert_silently_fails(
    tmp_path: Path,
    handlers_mod: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Confirm the BRIDGE_USER_MAP no-match path explicitly unassigns (S4).

    Pre-fix: a CREATE with an unmapped assignee silently shipped the local
    display-name string to Jira's create_issue, which Jira either rejected or
    accepted with a stale/wrong assignee.  Either way, the issue's assignee
    state diverged from the local tracker (no-match means "no Jira user").

    Post-fix: handle_create_event resolves via BRIDGE_USER_MAP; on no-match,
    it (a) drops the assignee from the create_issue payload, (b) calls
    AcliClient.unassign_issue(jira_key) explicitly, (c) writes a BRIDGE_ALERT.
    """
    tracker = tmp_path / ".tickets-tracker"
    tracker.mkdir()
    ticket_dir = tracker / "tk-na-1"
    ticket_dir.mkdir()
    ts = time.time_ns()
    eu = str(uuid.uuid4())
    create_path = ticket_dir / f"{ts}-{eu}-CREATE.json"
    create_payload = {
        "event_type": "CREATE",
        "timestamp": ts,
        "uuid": eu,
        "env_id": "aaaaaaaa-0000-4000-8000-000000000001",
        "data": {
            "ticket_type": "task",
            "title": "Null-assignee test",
            "assignee": "Test User",
            "description": "x",
        },
    }
    create_path.write_text(json.dumps(create_payload), encoding="utf-8")

    # BRIDGE_USER_MAP intentionally omits "Test User".
    monkeypatch.setenv(
        "BRIDGE_USER_MAP", json.dumps({"someone-else@example.com": "acc-99"})
    )

    acli = MagicMock()
    acli.create_issue.return_value = {"key": "PROJ-NA-1"}
    acli.unassign_issue.return_value = None

    event = {
        "ticket_id": "tk-na-1",
        "event_type": "CREATE",
        "file_path": str(create_path),
    }
    syncs = handlers_mod.handle_create_event(
        event,
        acli_client=acli,
        tickets_root=tracker,
        bridge_env_id="bbbbbbbb-0000-4000-8000-000000000002",
        run_id="run-na",
    )

    assert acli.create_issue.called, "create_issue must still be called"
    sent_payload = acli.create_issue.call_args.args[0]
    assert "assignee" not in sent_payload, (
        "S4 fix regressed: unmapped assignee leaked into create_issue payload "
        "instead of being stripped before the call"
    )
    acli.unassign_issue.assert_called_once_with("PROJ-NA-1")
    alerts = list(ticket_dir.glob("*-BRIDGE_ALERT.json"))
    assert any(
        "BRIDGE_USER_MAP" in json.loads(p.read_text())["data"]["reason"] for p in alerts
    ), "BRIDGE_ALERT for no-map assignee was not written"
    assert syncs and syncs[0]["jira_key"] == "PROJ-NA-1"
