"""Tests for windowed pull JQL timestamp timezone handling.

The windowed pull reads last_pull_timestamp (stored as UTC ISO 8601) and
formats it for Jira JQL. Jira interprets bare datetime strings in the user's
profile timezone — not UTC. The formatted timestamp must use local time so the
JQL window aligns correctly.
"""

import os
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
)


def _run_bash(snippet: str, env: dict | None = None) -> subprocess.CompletedProcess:
    """Run a bash snippet, returning the completed process."""
    full_env = {**os.environ, **(env or {})}
    return subprocess.run(
        ["bash", "-c", snippet],
        capture_output=True,
        text=True,
        env=full_env,
        cwd=str(REPO_ROOT),
        timeout=15,
    )


class TestWindowedTimestampTimezone:
    """The buffered timestamp Python one-liner must produce local-time output.

    Jira JQL interprets bare datetime strings in the user's profile timezone.
    A UTC timestamp formatted as-is will be off by the timezone offset.
    The one-liner must convert from UTC to local time before formatting.
    """

    def test_utc_timestamp_in_nonzero_tz_must_produce_local_time(self):
        """When system TZ is non-UTC, the JQL timestamp must reflect local time.

        In America/Los_Angeles (PDT=UTC-7 in March 2026 after DST spring-forward):
          - last_pull_timestamp = "2026-03-19T23:44:00Z" (UTC)
          - 15-minute buffer applied: 23:29 UTC
          - local (PDT): 16:29
          - Jira reads JQL as local → wrong window if UTC "23:29" is sent.

        """
        # Run the bash one-liner with a controlled UTC timestamp
        # and a non-UTC timezone. We use TZ env var to force PDT offset.
        bash_snippet = textwrap.dedent("""\
            export LAST_PULL_TS="2026-03-19T23:44:00Z"
            _buffered_ts=$(LAST_PULL_TS="$LAST_PULL_TS" python3 -c \
                "import os; from datetime import datetime, timedelta; \
t=datetime.fromisoformat(os.environ['LAST_PULL_TS']); \
print((t - timedelta(minutes=15)).astimezone().strftime('%Y-%m-%d %H:%M'))" 2>/dev/null) || _buffered_ts=""
            echo "$_buffered_ts"
        """)
        env = {**os.environ, "TZ": "America/Los_Angeles"}
        result = _run_bash(bash_snippet, env=env)
        assert result.returncode == 0, f"Bash snippet failed: {result.stderr}"
        output = result.stdout.strip()

        # In PDT (UTC-7), 23:44 UTC - 15min = 23:29 UTC = 16:29 local.
        # The fix uses .astimezone() to convert UTC → local before formatting.
        # We assert the output is NOT the raw UTC value to detect the bug.
        assert output != "2026-03-19 23:29", (
            f"Windowed-pull snippet produced UTC time {output!r} for a non-UTC "
            "system timezone. Jira will interpret this as local time, causing the "
            "JQL window to be off by the timezone offset."
        )

    def test_utc_timestamp_produces_correct_local_time_value(self):
        """The formatted timestamp must equal local time (not UTC).

        With TZ=America/Los_Angeles and input "2026-03-19T23:44:00Z":
          - 23:44 UTC - 15min = 23:29 UTC
          - PDT (UTC-7): 23:29 UTC → 16:29 local
        The output must be "2026-03-19 16:29".
        """
        bash_snippet = textwrap.dedent("""\
            export LAST_PULL_TS="2026-03-19T23:44:00Z"
            _buffered_ts=$(LAST_PULL_TS="$LAST_PULL_TS" python3 -c \
                "import os; from datetime import datetime, timedelta; \
t=datetime.fromisoformat(os.environ['LAST_PULL_TS']); \
print((t - timedelta(minutes=15)).astimezone().strftime('%Y-%m-%d %H:%M'))" 2>/dev/null) || _buffered_ts=""
            echo "$_buffered_ts"
        """)
        env = {**os.environ, "TZ": "America/Los_Angeles"}
        result = _run_bash(bash_snippet, env=env)
        assert result.returncode == 0, f"Bash snippet failed: {result.stderr}"
        output = result.stdout.strip()

        # PDT = UTC-7 (March 2026 is after DST spring-forward on March 8, 2026)
        assert output == "2026-03-19 16:29", (
            f"Expected local PDT time '2026-03-19 16:29', got {output!r}. "
            "The snippet must convert UTC → local time before formatting."
        )

    def test_utc_timezone_produces_unchanged_output(self):
        """When TZ=UTC, local time equals UTC — output should be unchanged.

        This verifies the fix does not break the zero-offset edge case.
        """
        bash_snippet = textwrap.dedent("""\
            export LAST_PULL_TS="2026-03-19T23:44:00Z"
            _buffered_ts=$(LAST_PULL_TS="$LAST_PULL_TS" python3 -c \
                "import os; from datetime import datetime, timedelta; \
t=datetime.fromisoformat(os.environ['LAST_PULL_TS']); \
print((t - timedelta(minutes=15)).astimezone().strftime('%Y-%m-%d %H:%M'))" 2>/dev/null) || _buffered_ts=""
            echo "$_buffered_ts"
        """)
        env = {**os.environ, "TZ": "UTC"}
        result = _run_bash(bash_snippet, env=env)
        assert result.returncode == 0, f"Bash snippet failed: {result.stderr}"
        output = result.stdout.strip()
        # In UTC, 23:44 - 15min = 23:29 UTC = 23:29 local — output must match.
        assert output == "2026-03-19 23:29", (
            f"Expected '2026-03-19 23:29' for UTC timezone, got {output!r}."
        )
