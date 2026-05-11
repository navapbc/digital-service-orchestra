"""Tests for the outbound-bridge SHA-based cursor checkpoint (5d93-8b62).

The cursor replaces the chronic HEAD~1..HEAD diff with a persistent
last-processed-SHA checkpoint, ensuring that all commits since the previous
run are processed even if multiple commits land between runs.
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

# Ensure the scripts directory is on sys.path so `bridge._outbound_cursor` resolves.
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))


def _load_bridge() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "bridge_outbound", SCRIPT_DIR / "bridge-outbound.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def bridge() -> ModuleType:
    return _load_bridge()


@pytest.fixture()
def cursor_mod() -> ModuleType:
    from bridge import _outbound_cursor  # noqa: PLC0415

    return _outbound_cursor


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


def _make_tmp_git_tracker(tmp_path: Path) -> Path:
    """Initialise a temp git repo with a baseline commit and return its path."""
    repo = tmp_path / ".tickets-tracker"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "tickets")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test")
    (repo / "README.md").write_text("baseline\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-q", "-m", "baseline")
    return repo


def _commit_event(
    repo: Path, ticket_id: str, event_type: str = "STATUS"
) -> tuple[str, Path]:
    """Add a new event JSON file under ticket_id and commit it. Returns (sha, path)."""
    ticket_dir = repo / ticket_id
    ticket_dir.mkdir(exist_ok=True)
    ts = time.time_ns()
    eu = str(uuid.uuid4())
    filename = f"{ts}-{eu}-{event_type}.json"
    payload = {
        "event_type": event_type,
        "timestamp": ts,
        "uuid": eu,
        "env_id": "aaaaaaaa-0000-4000-8000-000000000001",
        "data": {"status": "in_progress"} if event_type == "STATUS" else {},
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload), encoding="utf-8")
    _git(repo, "add", str(path.relative_to(repo)))
    _git(repo, "commit", "-q", "-m", f"add {event_type} for {ticket_id}")
    sha = _git(repo, "rev-parse", "HEAD").stdout.strip()
    return sha, path


# ---------------------------------------------------------------------------
# read_cursor / write_cursor
# ---------------------------------------------------------------------------


def test_read_cursor_no_file(tmp_path: Path, cursor_mod: ModuleType) -> None:
    assert cursor_mod.read_cursor(tmp_path) is None


def test_read_cursor_malformed_json(tmp_path: Path, cursor_mod: ModuleType) -> None:
    (tmp_path / cursor_mod.CHECKPOINT_FILENAME).write_text(
        "not-json{", encoding="utf-8"
    )
    assert cursor_mod.read_cursor(tmp_path) is None


def test_read_cursor_missing_sha_field(tmp_path: Path, cursor_mod: ModuleType) -> None:
    (tmp_path / cursor_mod.CHECKPOINT_FILENAME).write_text(
        json.dumps({"some_other_field": "x"}), encoding="utf-8"
    )
    assert cursor_mod.read_cursor(tmp_path) is None


def test_write_cursor_advances(tmp_path: Path, cursor_mod: ModuleType) -> None:
    sha = "a" * 40
    cursor_mod.write_cursor(tmp_path, sha, run_id="run-1")
    assert cursor_mod.read_cursor(tmp_path) == sha
    new_sha = "b" * 40
    cursor_mod.write_cursor(tmp_path, new_sha, run_id="run-2")
    assert cursor_mod.read_cursor(tmp_path) == new_sha
    payload = json.loads(
        (tmp_path / cursor_mod.CHECKPOINT_FILENAME).read_text(encoding="utf-8")
    )
    assert payload["last_processed_sha"] == new_sha
    assert payload["last_run_id"] == "run-2"


# ---------------------------------------------------------------------------
# fetch_events_since_cursor
# ---------------------------------------------------------------------------


def test_fetch_events_three_commits(tmp_path: Path, cursor_mod: ModuleType) -> None:
    """When 3 commits land after the cursor, all 3 events are returned."""
    repo = _make_tmp_git_tracker(tmp_path)
    base_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    sha1, _ = _commit_event(repo, "ticket-aaaa", "STATUS")
    sha2, _ = _commit_event(repo, "ticket-bbbb", "STATUS")
    sha3, _ = _commit_event(repo, "ticket-cccc", "STATUS")

    events = cursor_mod.fetch_events_since_cursor(repo, base_sha)
    assert len(events) == 3
    seen_shas = {e["commit_sha"] for e in events}
    assert seen_shas == {sha1, sha2, sha3}
    seen_tickets = {e["ticket_id"] for e in events}
    assert seen_tickets == {"ticket-aaaa", "ticket-bbbb", "ticket-cccc"}
    for e in events:
        assert e["event_type"] == "STATUS"


def test_cold_start_returns_full_history(
    tmp_path: Path, cursor_mod: ModuleType
) -> None:
    """Cold-start (bug f8a9-2cb0): no cursor → walk full tracker history and
    return ALL pre-existing CREATE/event files.

    Previously, cold-start seeded at HEAD and returned [], causing the first
    bridge run against a tracker with pre-existing tickets to silently drop
    every CREATE event (157 tickets in the production case).
    """
    repo = _make_tmp_git_tracker(tmp_path)
    sha1, _ = _commit_event(repo, "ticket-aaaa", "CREATE")
    sha2, _ = _commit_event(repo, "ticket-bbbb", "CREATE")
    sha3, _ = _commit_event(repo, "ticket-cccc", "STATUS")

    events = cursor_mod.fetch_events_since_cursor(repo, None)
    assert len(events) == 3, (
        "cold-start must return pre-existing events, not silently drop them"
    )
    seen_tickets = {e["ticket_id"] for e in events}
    assert seen_tickets == {"ticket-aaaa", "ticket-bbbb", "ticket-cccc"}
    seen_shas = {e["commit_sha"] for e in events}
    assert seen_shas == {sha1, sha2, sha3}


def test_cold_start_cap_exceeded_seeds_at_head(
    tmp_path: Path, cursor_mod: ModuleType
) -> None:
    """Cold-start with history > cap → BRIDGE_ALERT + seed at HEAD, return [].

    Cap protection still applies to cold-start to avoid unbounded backfills.
    """
    repo = _make_tmp_git_tracker(tmp_path)
    for i in range(5):
        _commit_event(repo, f"ticket-{i:04d}", "CREATE")
    head_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    # cap=2 < 5 distinct commits → cap-exceeded path
    events = cursor_mod.fetch_events_since_cursor(repo, None, cap=2)
    assert events == []
    assert cursor_mod.read_cursor(repo) == head_sha
    alert_dir = repo / "__bridge__"
    assert alert_dir.is_dir()
    alerts = list(alert_dir.glob("*-BRIDGE_ALERT.json"))
    # cap-exceeded path writes a cap alert + the cold-start seed alert
    assert len(alerts) >= 1
    reasons = [
        json.loads(a.read_text(encoding="utf-8"))["data"]["reason"] for a in alerts
    ]
    assert any("cap exceeded" in r for r in reasons)


def test_unreachable_sha_seeds_at_head(tmp_path: Path, cursor_mod: ModuleType) -> None:
    repo = _make_tmp_git_tracker(tmp_path)
    _commit_event(repo, "ticket-zzzz", "STATUS")
    head_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    bogus_sha = "f" * 40
    events = cursor_mod.fetch_events_since_cursor(repo, bogus_sha)
    assert events == []
    assert cursor_mod.read_cursor(repo) == head_sha


# ---------------------------------------------------------------------------
# process_events integrates cursor (multi-commit catches all events)
# ---------------------------------------------------------------------------


def test_process_events_multi_commit_catches_all_events(
    tmp_path: Path, bridge: ModuleType, cursor_mod: ModuleType
) -> None:
    """Bug fix: when multiple commits land between bridge runs, ALL events are
    processed (not just HEAD~1..HEAD).

    This is the chronic 'HEAD~1 blindness' bug — the existing diff command
    misses events committed in earlier-but-still-new commits.
    """
    repo = _make_tmp_git_tracker(tmp_path)

    # Seed a starting cursor at the baseline commit so subsequent commits are
    # all "new" relative to the cursor.
    base_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()
    cursor_mod.write_cursor(repo, base_sha, run_id="prev-run")

    # Three commits, three new STATUS events.
    _commit_event(repo, "ticket-1111", "STATUS")
    _commit_event(repo, "ticket-2222", "STATUS")
    _commit_event(repo, "ticket-3333", "STATUS")
    new_head = _git(repo, "rev-parse", "HEAD").stdout.strip()

    # Build a mock acli client; STATUS events don't drive create_issue.
    acli = MagicMock()

    # bridge_env_id different from event env_id so events aren't filtered out.
    bridge.process_events(
        tickets_dir=repo,
        acli_client=acli,
        bridge_env_id="bbbbbbbb-0000-4000-8000-000000000002",
        run_id="run-current",
    )

    # Cursor must advance to the latest commit, not stay at base.
    assert cursor_mod.read_cursor(repo) == new_head, (
        "cursor must advance past all three commits; staying at base means the "
        "HEAD~1 blindness bug is still present"
    )


def test_fetch_events_file_path_resolvable_for_create_event(
    tmp_path: Path, cursor_mod: ModuleType
) -> None:
    """file_path in returned events must be resolvable to read event data.

    When git log emits bare relative paths (no .tickets-tracker/ prefix),
    the stored file_path must be absolute so _read_event_file can open it
    regardless of process CWD (jira-dig-2163).
    """
    from bridge._outbound_api import read_event_file  # noqa: PLC0415

    repo = _make_tmp_git_tracker(tmp_path)
    base_sha = _git(repo, "rev-parse", "HEAD").stdout.strip()

    ticket_dir = repo / "ticket-create-1234"
    ticket_dir.mkdir(exist_ok=True)
    ts = time.time_ns()
    eu = str(uuid.uuid4())
    filename = f"{ts}-{eu}-CREATE.json"
    expected_title = "My Human Readable Title"
    payload = {
        "event_type": "CREATE",
        "timestamp": ts,
        "uuid": eu,
        "env_id": "aaaaaaaa-0000-4000-8000-000000000001",
        "data": {"ticket_type": "epic", "title": expected_title},
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload), encoding="utf-8")
    _git(repo, "add", str(path.relative_to(repo)))
    _git(repo, "commit", "-q", "-m", "add CREATE for ticket-create-1234")

    events = cursor_mod.fetch_events_since_cursor(repo, base_sha)
    assert len(events) == 1
    assert events[0]["event_type"] == "CREATE"

    event_data = read_event_file(events[0]["file_path"])
    assert event_data is not None, (
        f"file_path {events[0]['file_path']!r} could not be opened — "
        "bare relative path not resolvable from process CWD"
    )
    assert event_data.get("data", {}).get("title") == expected_title
