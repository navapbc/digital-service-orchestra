"""Tests for analyze-precompact-telemetry.sh.

Verifies that the analysis script reads JSONL telemetry and produces
correct human-readable and JSON summaries.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
ANALYZE_SCRIPT = os.path.join(
    REPO_ROOT, "lockpick-workflow/scripts/analyze-precompact-telemetry.sh"
)

# 5-entry fixture across 2 sessions:
#   Session A (sess-A): 2 skipped + 1 committed = 3
#   Session B (sess-B): 2 exited_early = 2
# Entry 4 (session B, first) has null context_tokens → potentially spurious
FIXTURE_ENTRIES = [
    {
        "timestamp": "2026-03-13T10:00:00Z",
        "session_id": "sess-A",
        "parent_session_id": None,
        "context_tokens": 80000,
        "context_limit": 200000,
        "active_task_count": 1,
        "git_dirty": False,
        "hook_outcome": "skipped",
        "exit_reason": "no_real_changes",
        "working_directory": "/tmp/test",
        "duration_ms": 15,
    },
    {
        "timestamp": "2026-03-13T10:05:00Z",
        "session_id": "sess-A",
        "parent_session_id": None,
        "context_tokens": 120000,
        "context_limit": 200000,
        "active_task_count": 2,
        "git_dirty": True,
        "hook_outcome": "skipped",
        "exit_reason": "no_real_changes",
        "working_directory": "/tmp/test",
        "duration_ms": 12,
    },
    {
        "timestamp": "2026-03-13T10:10:00Z",
        "session_id": "sess-A",
        "parent_session_id": None,
        "context_tokens": 150000,
        "context_limit": 200000,
        "active_task_count": 3,
        "git_dirty": True,
        "hook_outcome": "committed",
        "exit_reason": "committed",
        "working_directory": "/tmp/test",
        "duration_ms": 250,
    },
    {
        "timestamp": "2026-03-13T11:00:00Z",
        "session_id": "sess-B",
        "parent_session_id": "parent-B",
        "context_tokens": None,
        "context_limit": 200000,
        "active_task_count": 0,
        "git_dirty": False,
        "hook_outcome": "exited_early",
        "exit_reason": "env_var_disabled",
        "working_directory": "/tmp/test2",
        "duration_ms": 5,
    },
    {
        "timestamp": "2026-03-13T11:02:00Z",
        "session_id": "sess-B",
        "parent_session_id": "parent-B",
        "context_tokens": 50000,
        "context_limit": 200000,
        "active_task_count": 0,
        "git_dirty": False,
        "hook_outcome": "exited_early",
        "exit_reason": "env_var_disabled",
        "working_directory": "/tmp/test2",
        "duration_ms": 4,
    },
]


@pytest.fixture
def fixture_jsonl(tmp_path: Path) -> Path:
    """Write the 5-entry fixture to a temporary JSONL file."""
    jsonl_file = tmp_path / "telemetry.jsonl"
    lines = [json.dumps(entry) for entry in FIXTURE_ENTRIES]
    jsonl_file.write_text("\n".join(lines) + "\n")
    return jsonl_file


def _run_script(
    jsonl_path: Path, extra_args: list[str] | None = None
) -> subprocess.CompletedProcess:
    """Run the analysis script and return the result."""
    cmd = ["bash", ANALYZE_SCRIPT]
    if extra_args:
        cmd.extend(extra_args)
    cmd.append(str(jsonl_path))
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


class TestAnalyzePrecompactTelemetryHumanOutput:
    """Test human-readable output mode."""

    def test_total_fire_count(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl)
        assert result.returncode == 0
        # Should show total of 5
        assert "5" in result.stdout

    def test_per_session_counts(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl)
        output = result.stdout
        # Session A has 3 fires, session B has 2
        assert "sess-A" in output
        assert "sess-B" in output
        # The counts 3 and 2 should appear near their session IDs
        assert "3" in output
        assert "2" in output

    def test_outcome_breakdown(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl)
        output = result.stdout
        assert "committed" in output
        assert "skipped" in output
        assert "exited_early" in output

    def test_null_context_tokens_flagged(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl)
        output = result.stdout.lower()
        assert "spurious" in output or "potentially spurious" in output.lower()

    def test_time_relative_to_first_fire(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl)
        output = result.stdout
        # First entry in each session should show +0s or similar
        assert "+0" in output or "0:00" in output or "0s" in output


class TestAnalyzePrecompactTelemetryJsonOutput:
    """Test --json machine-readable output mode."""

    def test_json_flag_produces_valid_json(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl, extra_args=["--json"])
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert isinstance(data, dict)

    def test_json_total_fires(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl, extra_args=["--json"])
        data = json.loads(result.stdout)
        assert data["total_fires"] == 5

    def test_json_per_session(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl, extra_args=["--json"])
        data = json.loads(result.stdout)
        sessions = data["sessions"]
        # Find session A and B
        sess_a = next(s for s in sessions if s["session_id"] == "sess-A")
        sess_b = next(s for s in sessions if s["session_id"] == "sess-B")
        assert sess_a["fire_count"] == 3
        assert sess_b["fire_count"] == 2

    def test_json_outcome_breakdown(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl, extra_args=["--json"])
        data = json.loads(result.stdout)
        outcomes = data["outcome_breakdown"]
        assert outcomes["committed"] == 1
        assert outcomes["skipped"] == 2
        assert outcomes["exited_early"] == 2

    def test_json_potentially_spurious(self, fixture_jsonl: Path) -> None:
        result = _run_script(fixture_jsonl, extra_args=["--json"])
        data = json.loads(result.stdout)
        spurious = data["potentially_spurious"]
        assert len(spurious) == 1
        assert spurious[0]["session_id"] == "sess-B"
        assert spurious[0]["context_tokens"] is None


class TestAnalyzePrecompactTelemetryEdgeCases:
    """Test error handling and edge cases."""

    def test_missing_arguments_exits_nonzero(self) -> None:
        result = subprocess.run(
            ["bash", ANALYZE_SCRIPT],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode != 0

    def test_nonexistent_file_exits_nonzero(self) -> None:
        result = subprocess.run(
            ["bash", ANALYZE_SCRIPT, "/tmp/nonexistent-telemetry-file.jsonl"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode != 0

    def test_empty_file(self, tmp_path: Path) -> None:
        empty = tmp_path / "empty.jsonl"
        empty.write_text("")
        result = _run_script(empty)
        assert result.returncode == 0
        assert "0" in result.stdout
