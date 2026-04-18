"""RED unit tests for semantic-conflict-check.py fail-open behavior.

Ticket: f845-1a0a — when model.haiku is not configured, semantic-conflict-check
should return {"clean": true} (fail-open) rather than FATAL + sys.exit(1).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path
from unittest import mock

import pytest

# ---------------------------------------------------------------------------
# Module import
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "semantic-conflict-check.py"

if not SCRIPT_PATH.exists():
    raise ImportError(f"semantic-conflict-check.py not found at {SCRIPT_PATH}")

spec = importlib.util.spec_from_file_location("semantic_conflict_check", SCRIPT_PATH)
_module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
spec.loader.exec_module(_module)  # type: ignore[union-attr]

main = _module.main
_resolve_model_id = _module._resolve_model_id


# ---------------------------------------------------------------------------
# Fail-open behavior when model ID not configured (f845-1a0a)
# ---------------------------------------------------------------------------


class TestModelIdFailOpen:
    """Verify semantic-conflict-check fails open when haiku model not configured."""

    def test_main_exits_0_when_model_id_missing(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """When resolve-model-id.sh fails (model.haiku absent), main() exits 0 (fail-open).

        RED: fails before fix because sys.exit(1) is called instead.
        GREEN: passes after fail-open behavior wraps the model resolution.
        """
        fake_diff = "diff --git a/foo.py b/foo.py\n+x = 1\n"
        resolve_error = subprocess.CalledProcessError(
            returncode=1,
            cmd=["bash", "resolve-model-id.sh", "haiku"],
            stderr="Error: config key 'model.haiku' is absent or empty",
        )
        with (
            mock.patch.object(
                _module.subprocess,
                "check_output",
                side_effect=resolve_error,
            ),
            mock.patch("sys.argv", ["semantic-conflict-check.py"]),
            mock.patch("sys.stdin") as mock_stdin,
        ):
            mock_stdin.read.return_value = fake_diff
            try:
                exit_code = main()
            except SystemExit as e:
                exit_code = e.code

        assert exit_code == 0, (
            f"Expected exit 0 (fail-open when haiku not configured), got exit {exit_code}"
        )

    def test_subprocess_failure_produces_clean_json_output(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """CalledProcessError from resolve-model-id.sh -> clean=true JSON on stdout.

        RED: fails before fix because sys.exit(1) kills the process with no JSON.
        GREEN: passes after fail-open JSON response is implemented.
        """
        fake_diff = "diff --git a/foo.py b/foo.py\n+x = 1\n"
        resolve_error = subprocess.CalledProcessError(
            returncode=1,
            cmd=["bash", "resolve-model-id.sh", "haiku"],
            stderr="Error: config key 'model.haiku' is absent or empty",
        )
        with (
            mock.patch.object(
                _module.subprocess,
                "check_output",
                side_effect=resolve_error,
            ),
            mock.patch("sys.argv", ["semantic-conflict-check.py"]),
            mock.patch("sys.stdin") as mock_stdin,
        ):
            mock_stdin.read.return_value = fake_diff
            try:
                main()
            except SystemExit as e:
                if e.code != 0:
                    pytest.fail(
                        f"main() called sys.exit({e.code}) instead of returning clean JSON"
                    )

        captured = capsys.readouterr()
        assert captured.out.strip(), "main() should print JSON to stdout on failure"
        result = json.loads(captured.out.strip())
        assert result.get("clean") is True, (
            f"Expected clean=true in fail-open response, got: {result}"
        )
        assert "error" in result, "Fail-open response should include 'error' field"
