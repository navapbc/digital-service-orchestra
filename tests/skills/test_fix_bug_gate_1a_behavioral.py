"""Behavioral tests for fix-bug Gate 1a config integration.

Replaces the change-detection tests in the original test_fix_bug_gate_1a.py
(deleted in Epic 902a-393b). Only the behavioral test (subprocess call to
read-config.sh) is preserved and expanded with edge-case coverage.
"""

import pathlib
import subprocess
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
READ_CONFIG_SCRIPT = REPO_ROOT / "plugins" / "dso" / "scripts" / "read-config.sh"


class TestFixBugGate1aConfigBehavior:
    """Behavioral tests that execute read-config.sh and assert on output."""

    def test_gate_1a_config_key_default(self) -> None:
        """read-config.sh returns '20' for debug.intent_search_budget."""
        result = subprocess.run(
            ["bash", str(READ_CONFIG_SCRIPT), "debug.intent_search_budget"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"Expected exit 0, got {result.returncode}. stderr: {result.stderr!r}"
        )
        assert result.stdout.strip() == "20", (
            f"Expected '20', got {result.stdout.strip()!r}"
        )

    def test_gate_1a_config_key_list_mode(self) -> None:
        """read-config.sh --list returns the value with exit 0."""
        result = subprocess.run(
            ["bash", str(READ_CONFIG_SCRIPT), "--list", "debug.intent_search_budget"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"Expected exit 0 in list mode, got {result.returncode}. stderr: {result.stderr!r}"
        )
        assert "20" in result.stdout, (
            f"Expected '20' in list mode output, got {result.stdout!r}"
        )

    def test_gate_1a_config_absent_key_returns_empty(self) -> None:
        """read-config.sh returns empty string for nonexistent key, exit 0."""
        result = subprocess.run(
            ["bash", str(READ_CONFIG_SCRIPT), "nonexistent.key.that.does.not.exist"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, (
            f"Expected exit 0 for absent key, got {result.returncode}. stderr: {result.stderr!r}"
        )
        assert result.stdout.strip() == "", (
            f"Expected empty output for absent key, got {result.stdout.strip()!r}"
        )

    def test_gate_1a_config_override_via_custom_file(self) -> None:
        """read-config.sh reads from a custom config file when WORKFLOW_CONFIG_FILE is set."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
            f.write("debug:\n  intent_search_budget: 42\n")
            f.flush()
            result = subprocess.run(
                ["bash", str(READ_CONFIG_SCRIPT), "debug.intent_search_budget"],
                capture_output=True,
                text=True,
                timeout=10,
                env={**__import__("os").environ, "WORKFLOW_CONFIG_FILE": f.name},
            )
        assert result.returncode == 0, (
            f"Expected exit 0 with custom config, got {result.returncode}. stderr: {result.stderr!r}"
        )
        assert result.stdout.strip() == "42", (
            f"Expected '42' from custom config, got {result.stdout.strip()!r}"
        )

    def test_gate_1a_config_missing_file_exits_0(self) -> None:
        """read-config.sh degrades gracefully when config file is missing."""
        result = subprocess.run(
            ["bash", str(READ_CONFIG_SCRIPT), "debug.intent_search_budget"],
            capture_output=True,
            text=True,
            timeout=10,
            env={
                **__import__("os").environ,
                "WORKFLOW_CONFIG_FILE": "/nonexistent/path.yaml",
            },
        )
        # Graceful degradation: exit 0 with empty output, not a crash
        assert result.returncode == 0, (
            f"Expected exit 0 for missing config file, got {result.returncode}. stderr: {result.stderr!r}"
        )
