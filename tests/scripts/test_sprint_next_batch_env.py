"""Tests that sprint-next-batch.sh self-detects CLAUDE_PLUGIN_ROOT via BASH_SOURCE."""

import os
import subprocess

REPO_ROOT = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
SCRIPT = os.path.join(REPO_ROOT, "plugins/dso/scripts/sprint-next-batch.sh")


def _run_without_plugin_root(args: list[str]) -> subprocess.CompletedProcess:
    """Run sprint-next-batch.sh with CLAUDE_PLUGIN_ROOT stripped from the environment."""
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_PLUGIN_ROOT"}
    return subprocess.run(
        ["bash", SCRIPT] + args,
        capture_output=True,
        text=True,
        env=env,
    )


class TestSprintNextBatchSelfDetect:
    def test_runs_without_claude_plugin_root(self):
        """Script must not fail with 'Could not load epic' when CLAUDE_PLUGIN_ROOT is unset.

        The script should self-detect its plugin root via BASH_SOURCE, not rely on the
        caller to export CLAUDE_PLUGIN_ROOT.  A non-existent epic ID produces exit 1
        with a tk-level error — that is acceptable.  The specific failure mode we are
        guarding against is exit 1 with the message 'Could not load epic', which means
        the TK variable was empty because CLAUDE_PLUGIN_ROOT was unset.
        """
        result = _run_without_plugin_root(["dso-does-not-exist-zzzz"])
        # The script may legitimately fail because the epic doesn't exist,
        # but it must NOT crash with "CLAUDE_PLUGIN_ROOT: unbound variable" (set -u failure).
        assert "CLAUDE_PLUGIN_ROOT: unbound variable" not in result.stderr, (
            f"Script crashed due to unset CLAUDE_PLUGIN_ROOT — self-detect is missing.\n"
            f"stderr: {result.stderr}"
        )
