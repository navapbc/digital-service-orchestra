"""Tests that worktree-cleanup.sh emits per-worktree progress lines to stderr
during the gather loop.

Bug 8f24-a2a5: With many worktrees the gather loop ran silently for 40+ seconds,
causing users to perceive a hang and kill the process.

The fix: emit a progress line to stderr for each worktree as it is being scanned,
so the user sees activity and can confirm the process is alive.

TDD: test_gather_loop_emits_worktree_names_to_stderr is the primary RED→GREEN test.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "worktree-cleanup.sh"


def _init_git_repo_with_worktrees(base: Path, num_worktrees: int = 3) -> Path:
    """Create a minimal git repo in *base* with *num_worktrees* named worktrees.

    Returns the path to the main repo root.
    """
    main_repo = base / "main-repo"
    main_repo.mkdir(parents=True)

    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "t@t.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "t@t.com",
    }

    def git(*args: str, cwd: Path = main_repo) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            env=env,
            check=True,
        )

    git("init", "-b", "main")
    git("config", "user.email", "test@test.com")
    git("config", "user.name", "Test")
    # Need at least one commit so HEAD is valid
    (main_repo / "README.md").write_text("test\n")
    git("add", "README.md")
    git("commit", "-m", "init")

    # Create numbered worktrees with their own branches
    worktree_names = []
    for i in range(num_worktrees):
        branch = f"worktree-scan-test-{i:02d}"
        wt_path = base / branch
        git("worktree", "add", "-b", branch, str(wt_path))
        worktree_names.append(branch)

    return main_repo


@pytest.mark.scripts
class TestGatherLoopProgress:
    """worktree-cleanup.sh emits per-worktree progress lines to stderr during gather."""

    def test_gather_loop_emits_worktree_names_to_stderr(self) -> None:
        """Given 3 git worktrees, when the cleanup script runs its gather loop,
        then each worktree's basename must appear in stderr output.

        RED: fails on the current script because the gather loop emits nothing to
        stderr — stderr is empty, so the assertion that each worktree name appears
        in stderr fails.

        GREEN: passes after the fix adds per-worktree progress lines to stderr
        (e.g., 'echo "Scanning worktree-scan-test-00..." >&2' inside the loop).

        The assertion is deliberately format-agnostic: it checks only that the
        worktree *name* appears in stderr, not the specific progress format (\\r,
        \\n, "Scanning", percentage, etc.). This means any reasonable progress
        implementation satisfies the test.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            base = Path(tmpdir)
            main_repo = _init_git_repo_with_worktrees(base, num_worktrees=3)

            # Create a fake home directory so the log file write doesn't fail
            # with a missing-directory error (would pollute stderr with noise).
            fake_home = base / "fake-home"
            fake_home.mkdir(parents=True, exist_ok=True)

            # Run the script with --dry-run --all so it traverses the gather loop
            # but does not actually remove anything.  We also pass --force to skip
            # interactive confirmation prompts that would block a non-TTY subprocess.
            result = subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "--dry-run",
                    "--all",
                    "--force",
                    "--include-branches",
                ],
                capture_output=True,
                text=True,
                cwd=str(main_repo),
                env={
                    **os.environ,
                    "HOME": str(fake_home),
                    # Prevent accidental Docker side effects
                    "CONFIG_COMPOSE_DB_FILE": "",
                    "CONFIG_COMPOSE_PROJECT": "",
                    # Keep AGE_HOURS small so worktrees are not filtered as "too recent"
                    "AGE_HOURS": "0",
                },
                timeout=60,
            )

        # The script may exit 0 or non-zero depending on whether there are
        # removable worktrees; we only care that it ran (no timeout/crash) and
        # that stderr captured progress output naming the worktrees.
        stderr = result.stderr

        # Each of the three worktree basenames must appear in stderr.
        # The gather loop sets `local_name=$(basename "$current_path")` and the
        # fix must emit that name (or the full path, which also contains it).
        for i in range(3):
            expected_name = f"worktree-scan-test-{i:02d}"
            assert expected_name in stderr, (
                f"Expected worktree name '{expected_name}' to appear in stderr "
                f"(progress output during the gather loop), but it was absent.\n"
                f"Full stderr:\n{stderr}\n"
                f"Full stdout:\n{result.stdout}\n"
                f"Exit code: {result.returncode}"
            )
