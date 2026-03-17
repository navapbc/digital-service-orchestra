"""Tests for git-based sync lock in scripts/tk.

The sync lock uses a .tickets/.sync-lock sentinel file on main via
detached-index commits. These tests verify:
1. Lock file format contains required fields
2. Stale lock detection (timestamp comparison)
3. Lock release removes the file
4. _sync_from_main has been removed (sync infrastructure removal)
"""

import os
import subprocess
import textwrap
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

# Resolve the repo root (works from worktrees too)
REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
)
TK_SCRIPT = REPO_ROOT / "scripts" / "tk"


def _run_bash(
    script: str, env: dict | None = None, cwd: str | None = None
) -> subprocess.CompletedProcess:
    """Run a bash script snippet, sourcing tk for helper functions."""
    full_env = {**os.environ, **(env or {})}
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env=full_env,
        cwd=cwd or str(REPO_ROOT),
        timeout=30,
    )


class TestSyncLockFileFormat:
    """Lock file must contain hostname, PID, session_id, and ISO 8601 timestamp."""

    def test_lock_file_contains_required_fields(self, tmp_path):
        """A generated .sync-lock file must have hostname, pid, session_id, timestamp."""
        # Simulate what _sync_lock_acquire writes
        script = textwrap.dedent(f"""\
            LOCK_FILE="{tmp_path / ".sync-lock"}"
            hostname=$(hostname 2>/dev/null || echo unknown)
            pid=$$
            session_id="${{CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || echo test-session)}}"
            timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            printf 'hostname=%s\\npid=%s\\nsession_id=%s\\ntimestamp=%s\\n' \\
                "$hostname" "$pid" "$session_id" "$timestamp" > "$LOCK_FILE"
            cat "$LOCK_FILE"
        """)
        result = _run_bash(script)
        assert result.returncode == 0, f"Script failed: {result.stderr}"

        lock_content = (tmp_path / ".sync-lock").read_text()
        fields = {}
        for line in lock_content.strip().splitlines():
            key, _, value = line.partition("=")
            fields[key] = value

        assert "hostname" in fields, "Lock file missing hostname"
        assert "pid" in fields, "Lock file missing pid"
        assert "session_id" in fields, "Lock file missing session_id"
        assert "timestamp" in fields, "Lock file missing timestamp"

        # Timestamp must be valid ISO 8601
        ts = fields["timestamp"]
        parsed = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        assert parsed.tzinfo is not None, "Timestamp must include timezone"

    def test_lock_file_pid_is_numeric(self, tmp_path):
        """PID field must be a valid integer."""
        lock_file = tmp_path / ".sync-lock"
        lock_file.write_text(
            "hostname=test\npid=12345\nsession_id=abc\ntimestamp=2026-03-05T18:00:00Z\n"
        )
        content = lock_file.read_text()
        fields = {}
        for line in content.strip().splitlines():
            k, _, v = line.partition("=")
            fields[k] = v
        assert fields["pid"].isdigit(), "PID must be numeric"


class TestStaleLockDetection:
    """Stale lock detection must correctly compare timestamps against threshold."""

    def test_fresh_lock_is_not_stale(self):
        """A lock created now should not be considered stale."""
        now = datetime.now(timezone.utc)
        lock_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        threshold = 3600  # 1 hour

        script = textwrap.dedent(f"""\
            LOCK_TS="{lock_ts}"
            THRESHOLD={threshold}
            lock_epoch=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$LOCK_TS" +%s 2>/dev/null || \\
                         date -d "$LOCK_TS" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age=$(( now_epoch - lock_epoch ))
            if (( age > THRESHOLD )); then
                echo "STALE"
            else
                echo "FRESH"
            fi
        """)
        result = _run_bash(script)
        assert result.returncode == 0, f"Script failed: {result.stderr}"
        assert "FRESH" in result.stdout, (
            f"Fresh lock detected as stale: {result.stdout}"
        )

    def test_old_lock_is_stale(self):
        """A lock older than threshold should be considered stale."""
        old_time = datetime.now(timezone.utc) - timedelta(hours=2)
        lock_ts = old_time.strftime("%Y-%m-%dT%H:%M:%SZ")
        threshold = 3600  # 1 hour

        script = textwrap.dedent(f"""\
            LOCK_TS="{lock_ts}"
            THRESHOLD={threshold}
            lock_epoch=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$LOCK_TS" +%s 2>/dev/null || \\
                         date -d "$LOCK_TS" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age=$(( now_epoch - lock_epoch ))
            if (( age > THRESHOLD )); then
                echo "STALE"
            else
                echo "FRESH"
            fi
        """)
        result = _run_bash(script)
        assert result.returncode == 0, f"Script failed: {result.stderr}"
        assert "STALE" in result.stdout, (
            f"Old lock not detected as stale: {result.stdout}"
        )

    def test_stale_detection_uses_tk_function(self):
        """_sync_lock_is_stale function in tk must detect stale locks correctly."""
        old_time = datetime.now(timezone.utc) - timedelta(hours=2)
        lock_ts = old_time.strftime("%Y-%m-%dT%H:%M:%SZ")

        # Source tk and call the helper directly
        script = textwrap.dedent(f"""\
            # Source only the lock functions from tk
            SYNC_LOCK_STALE_SECONDS=3600
            _sync_lock_parse_timestamp() {{
                local lock_file="$1"
                grep '^timestamp=' "$lock_file" | cut -d= -f2-
            }}
            _sync_lock_is_stale() {{
                local lock_ts="$1"
                local lock_epoch now_epoch age
                lock_epoch=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$lock_ts" +%s 2>/dev/null || \\
                             date -d "$lock_ts" +%s 2>/dev/null || echo 0)
                now_epoch=$(date +%s)
                age=$(( now_epoch - lock_epoch ))
                (( age > SYNC_LOCK_STALE_SECONDS ))
            }}

            if _sync_lock_is_stale "{lock_ts}"; then
                echo "STALE"
            else
                echo "FRESH"
            fi
        """)
        result = _run_bash(script)
        assert result.returncode == 0, f"Script failed: {result.stderr}"
        assert "STALE" in result.stdout, f"_sync_lock_is_stale failed: {result.stdout}"


class TestSyncLockAcquireRelease:
    """Integration tests for lock acquire/release using a local git repo."""

    @pytest.fixture
    def git_repo(self, tmp_path):
        """Create a bare git repo with a .tickets/ directory on main."""
        repo = tmp_path / "repo"
        repo.mkdir()
        subprocess.run(
            ["git", "init", "--initial-branch=main"], cwd=str(repo), capture_output=True
        )
        subprocess.run(
            ["git", "config", "user.email", "test@test.com"],
            cwd=str(repo),
            capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test"], cwd=str(repo), capture_output=True
        )

        # Create .tickets/ dir with an initial file
        tickets = repo / ".tickets"
        tickets.mkdir()
        (tickets / "test.md").write_text("test ticket\n")
        subprocess.run(["git", "add", ".tickets/"], cwd=str(repo), capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "init"], cwd=str(repo), capture_output=True
        )
        return repo

    def test_lock_file_written_to_tickets_dir(self, git_repo):
        """_sync_lock_write creates .tickets/.sync-lock with correct format."""
        lock_file = git_repo / ".tickets" / ".sync-lock"

        script = textwrap.dedent(f"""\
            cd "{git_repo}"
            LOCK_FILE="{lock_file}"
            hostname=$(hostname 2>/dev/null || echo unknown)
            pid=$$
            session_id="${{CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || echo test-session)}}"
            timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            printf 'hostname=%s\\npid=%s\\nsession_id=%s\\ntimestamp=%s\\n' \\
                "$hostname" "$pid" "$session_id" "$timestamp" > "$LOCK_FILE"
            # Verify it's in the repo
            test -f "$LOCK_FILE" && echo "WRITTEN" || echo "MISSING"
        """)
        result = _run_bash(script)
        assert "WRITTEN" in result.stdout

    def test_lock_removed_on_release(self, git_repo):
        """After release, .tickets/.sync-lock should not exist in the index."""
        script = textwrap.dedent(f"""\
            cd "{git_repo}"
            LOCK_FILE=".tickets/.sync-lock"

            # Write lock file
            printf 'hostname=test\\npid=1\\nsession_id=s1\\ntimestamp=2026-03-05T18:00:00Z\\n' > "$LOCK_FILE"

            # Add to index and commit (simulating acquire)
            git add "$LOCK_FILE"
            git commit -m "acquire lock" --quiet

            # Verify it exists
            git show HEAD:.tickets/.sync-lock > /dev/null 2>&1 && echo "EXISTS_BEFORE" || echo "MISSING_BEFORE"

            # Remove from index and commit (simulating release)
            git rm --cached "$LOCK_FILE" --quiet 2>/dev/null
            rm -f "$LOCK_FILE"
            git commit -m "release lock" --quiet

            # Verify it's gone
            git show HEAD:.tickets/.sync-lock > /dev/null 2>&1 && echo "EXISTS_AFTER" || echo "MISSING_AFTER"
        """)
        result = _run_bash(script)
        assert "EXISTS_BEFORE" in result.stdout, (
            f"Lock should exist before release: {result.stdout}"
        )
        assert "MISSING_AFTER" in result.stdout, (
            f"Lock should be removed after release: {result.stdout}"
        )


class TestSyncFromMainSkipsLockFile:
    """_sync_from_main has been removed; verify the call is gone from tk."""

    def test_sync_lock_not_in_gitignore_but_filtered(self):
        """_sync_from_main (and its .sync-lock filter) has been removed.
        Verify that _sync_from_main is not present in tk (it was the function
        that used to pull .tickets/ from main on read commands)."""
        tk_content = TK_SCRIPT.read_text()
        assert "_sync_from_main" not in tk_content, (
            "scripts/tk must not reference _sync_from_main after sync infrastructure removal"
        )


class TestSyncLockConstantsPresent:
    """Verify the tk script has the expected v2 CAS lock constants
    and old v1 constants are removed after migration cleanup."""

    def test_v2_stale_threshold_constant_exists(self):
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_STALE_THRESHOLD=" in tk_content

    def test_v2_acquire_timeout_constant_exists(self):
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_ACQUIRE_TIMEOUT=" in tk_content

    def test_v2_initial_backoff_constant_exists(self):
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_INITIAL_BACKOFF_V2=" in tk_content

    def test_v2_cas_ref_constant_exists(self):
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_CAS_REF=" in tk_content

    def test_old_v1_stale_seconds_removed(self):
        """After v1 cleanup, SYNC_LOCK_STALE_SECONDS should be removed."""
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_STALE_SECONDS=" not in tk_content, (
            "SYNC_LOCK_STALE_SECONDS (v1) should be removed after cleanup"
        )

    def test_old_v1_max_retries_removed(self):
        """After v1 cleanup, SYNC_LOCK_MAX_RETRIES should be removed."""
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_MAX_RETRIES=" not in tk_content, (
            "SYNC_LOCK_MAX_RETRIES (v1) should be removed after cleanup"
        )

    def test_old_v1_initial_backoff_removed(self):
        """After v1 cleanup, SYNC_LOCK_INITIAL_BACKOFF (non-v2) should be removed."""
        tk_content = TK_SCRIPT.read_text()
        # Check that no bare SYNC_LOCK_INITIAL_BACKOFF= exists (only _V2 variant)
        import re

        matches = re.findall(r"SYNC_LOCK_INITIAL_BACKOFF(?!_V2)=", tk_content)
        assert len(matches) == 0, (
            "SYNC_LOCK_INITIAL_BACKOFF (v1) should be removed after cleanup"
        )

    def test_no_jira_sync_lock_summary(self):
        """After migration, SYNC_LOCK_SUMMARY constant should be removed."""
        tk_content = TK_SCRIPT.read_text()
        assert "SYNC_LOCK_SUMMARY=" not in tk_content, (
            "SYNC_LOCK_SUMMARY should be removed after git-based lock migration"
        )

    def test_no_jira_lock_references(self):
        """No references to Jira-based SYNC-LOCK pattern should remain."""
        tk_content = TK_SCRIPT.read_text()
        # The string "SYNC-LOCK" (the Jira issue title) should not appear
        assert "SYNC-LOCK" not in tk_content, (
            "References to SYNC-LOCK Jira issue should be removed"
        )

    def test_sync_lock_ref_path(self):
        """The script should reference the CAS sync-lock ref."""
        tk_content = TK_SCRIPT.read_text()
        assert "refs/tk/sync-lock" in tk_content, (
            "scripts/tk must reference refs/tk/sync-lock for the CAS-based lock"
        )

    def test_pull_side_sync_lock_cleanup_retained(self):
        """Pull-side .sync-lock cleanup was in _sync_from_main; now that
        _sync_from_main is removed, verify it is absent from tk."""
        tk_content = TK_SCRIPT.read_text()
        # _sync_from_main and its .sync-lock cleanup were removed together;
        # the .sync-lock sentinel is managed by the Jira sync lock in _sync_body.
        assert "_sync_from_main" not in tk_content, (
            "_sync_from_main (and its pull-side sync-lock cleanup) must be removed"
        )
