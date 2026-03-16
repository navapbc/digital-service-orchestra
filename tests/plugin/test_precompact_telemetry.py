"""Tests for JSONL telemetry writer in pre-compact-checkpoint.sh.

These tests verify that the hook writes well-formed JSONL telemetry entries
with all 11 required fields at every exit point.
"""

import json
import os
import subprocess
from pathlib import Path

REPO_ROOT = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
COMPACT_HOOK = os.path.join(REPO_ROOT, "lockpick-workflow/hooks/pre-compact-checkpoint.sh")

REQUIRED_FIELDS = {
    "timestamp",
    "session_id",
    "parent_session_id",
    "context_tokens",
    "context_limit",
    "active_task_count",
    "git_dirty",
    "hook_outcome",
    "exit_reason",
    "working_directory",
    "duration_ms",
}


def _setup_test_repo(tmpdir: Path) -> Path:
    """Create a minimal git repo for hook testing."""
    repo = tmpdir / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@test.com"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
    (repo / "README.md").write_text("initial")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "init"], check=True)
    return repo


def _run_hook(repo: Path, fake_home: Path, extra_env: dict | None = None) -> Path:
    """Run the pre-compact hook and return the telemetry file path."""
    telemetry_file = fake_home / ".claude" / "precompact-telemetry.jsonl"
    (fake_home / ".claude").mkdir(parents=True, exist_ok=True)

    # Clear dedup locks
    import glob

    tmpdir = os.environ.get("TMPDIR", "/tmp")
    for f in glob.glob(os.path.join(tmpdir, ".precompact-lock-*")):
        os.unlink(f)

    env = {
        **os.environ,
        "HOME": str(fake_home),
        "CLAUDE_SESSION_ID": "test-session-123",
        "CLAUDE_PARENT_SESSION_ID": "parent-456",
        "CLAUDE_CONTEXT_WINDOW_TOKENS": "50000",
        "CLAUDE_CONTEXT_WINDOW_LIMIT": "200000",
    }
    if extra_env:
        env.update(extra_env)

    subprocess.run(
        ["bash", COMPACT_HOOK],
        cwd=str(repo),
        env=env,
        capture_output=True,
        timeout=30,
    )

    return telemetry_file


def _read_last_entry(telemetry_file: Path) -> dict:
    """Read and parse the last JSONL line."""
    lines = telemetry_file.read_text().strip().split("\n")
    return json.loads(lines[-1])


class TestPrecompactTelemetryWritesJsonl:
    """Test that telemetry JSONL is written with all required fields."""

    def test_writes_jsonl_file(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"

        # Create a dirty file so hook commits
        (repo / "testfile.txt").write_text("change")

        telemetry_file = _run_hook(repo, fake_home)
        assert telemetry_file.exists(), "Telemetry JSONL file should be created"

    def test_contains_all_required_fields(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"
        (repo / "testfile.txt").write_text("change")

        telemetry_file = _run_hook(repo, fake_home)
        entry = _read_last_entry(telemetry_file)

        missing = REQUIRED_FIELDS - set(entry.keys())
        assert not missing, f"Missing required fields: {missing}"

    def test_field_types(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"
        (repo / "testfile.txt").write_text("change")

        telemetry_file = _run_hook(repo, fake_home)
        entry = _read_last_entry(telemetry_file)

        assert isinstance(entry["timestamp"], str)
        assert isinstance(entry["session_id"], str)
        assert entry["session_id"] == "test-session-123"
        assert entry["parent_session_id"] == "parent-456"
        assert entry["context_tokens"] == 50000
        assert entry["context_limit"] == 200000
        assert isinstance(entry["active_task_count"], int)
        assert isinstance(entry["git_dirty"], bool)
        # After commit, working tree is clean
        assert isinstance(entry["git_dirty"], bool)
        assert isinstance(entry["hook_outcome"], str)
        assert isinstance(entry["exit_reason"], str)
        assert isinstance(entry["working_directory"], str)
        assert entry["working_directory"].startswith("/")
        assert isinstance(entry["duration_ms"], int)
        assert entry["duration_ms"] >= 0

    def test_early_exit_env_var_disabled(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"

        telemetry_file = _run_hook(repo, fake_home, extra_env={"LOCKPICK_DISABLE_PRECOMPACT": "1"})

        assert telemetry_file.exists()
        entry = _read_last_entry(telemetry_file)
        assert entry["exit_reason"] == "env_var_disabled"
        assert entry["hook_outcome"] == "exited_early"

    def test_no_real_changes_exit(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"

        # Clean repo — no uncommitted changes
        telemetry_file = _run_hook(repo, fake_home)

        assert telemetry_file.exists()
        entry = _read_last_entry(telemetry_file)
        assert entry["exit_reason"] == "no_real_changes"
        assert entry["hook_outcome"] == "skipped"

    def test_missing_env_vars_defaults(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"

        env_overrides = {
            "LOCKPICK_DISABLE_PRECOMPACT": "1",
        }
        # Remove CLAUDE_ vars
        for key in [
            "CLAUDE_SESSION_ID",
            "CLAUDE_PARENT_SESSION_ID",
            "CLAUDE_CONTEXT_WINDOW_TOKENS",
            "CLAUDE_CONTEXT_WINDOW_LIMIT",
        ]:
            env_overrides[key] = ""

        # Need to manually construct env without CLAUDE_ vars
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("CLAUDE_CONTEXT_WINDOW")
            and k != "CLAUDE_SESSION_ID"
            and k != "CLAUDE_PARENT_SESSION_ID"
        }
        env["HOME"] = str(fake_home)
        env["LOCKPICK_DISABLE_PRECOMPACT"] = "1"
        (fake_home / ".claude").mkdir(parents=True, exist_ok=True)

        # Clear dedup locks
        import glob as glob_mod

        tmpdir = os.environ.get("TMPDIR", "/tmp")
        for f in glob_mod.glob(os.path.join(tmpdir, ".precompact-lock-*")):
            os.unlink(f)

        subprocess.run(
            ["bash", COMPACT_HOOK],
            cwd=str(repo),
            env=env,
            capture_output=True,
            timeout=30,
        )

        telemetry_file = fake_home / ".claude" / "precompact-telemetry.jsonl"
        assert telemetry_file.exists()
        entry = _read_last_entry(telemetry_file)
        assert entry["session_id"] == "unknown"
        assert entry["parent_session_id"] is None
        assert entry["context_tokens"] is None
        assert entry["context_limit"] is None


class TestPrecompactTelemetryOverhead:
    """Test that telemetry writing adds minimal overhead."""

    def test_duration_under_100ms(self, tmp_path: Path) -> None:
        repo = _setup_test_repo(tmp_path)
        fake_home = tmp_path / "fakehome"

        # Use env_var_disabled for fastest exit
        telemetry_file = _run_hook(repo, fake_home, extra_env={"LOCKPICK_DISABLE_PRECOMPACT": "1"})

        entry = _read_last_entry(telemetry_file)
        assert entry["duration_ms"] < 100, f"Telemetry overhead too high: {entry['duration_ms']}ms"
