"""RED tests for bug 44de — ACLI exits 0 on mutation failure.

ACLI v1.3.18 returns exit=0 even when a mutation (edit/transition/assign/
label/comment/delete/link) fails. The reconciler treats exit=0 as success
and marks mutations applied, corrupting binding-store invariants and
breaking idempotent convergence.

Empirically verified shape (probe 2026-05-29):
    $ acli jira workitem edit --key DIG-99999 --summary fake --yes --json
    {
      "results": [{"status": "FAILURE", "message": "...", "id": "DIG-99999"}],
      "totalCount": 1,
      "successCount": 0
    }
    EXIT=0

Fix: ``_run_acli`` parses stdout; when the shape indicates failure
(successCount==0 or any results[].status == "FAILURE"), it raises
``AcliMutationError`` so the reconciler no longer treats it as success.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "acli-integration.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("acli_integration", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def acli() -> ModuleType:
    return _load_module()


# ---------------------------------------------------------------------------
# Test 1: edit mutation with FAILURE result raises AcliMutationError
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_edit_failure_via_json_raises(acli: ModuleType) -> None:
    """update_issue must raise AcliMutationError when ACLI's --json output
    reports FAILURE, even though the process exited 0."""
    failure_stdout = json.dumps(
        {
            "results": [
                {
                    "status": "FAILURE",
                    "message": "Issue does not exist or you do not have permission to see it.",
                    "id": "DIG-99999",
                }
            ],
            "totalCount": 1,
            "successCount": 0,
        }
    )
    mock_result = MagicMock(returncode=0, stdout=failure_stdout, stderr="")

    with (
        patch("subprocess.run", return_value=mock_result),
        pytest.raises(acli.AcliMutationError) as exc_info,
    ):
        acli.update_issue("DIG-99999", summary="new title")

    msg = str(exc_info.value)
    assert "DIG-99999" in msg or "does not exist" in msg or "permission" in msg, (
        f"AcliMutationError message should surface the FAILURE details, got: {msg!r}"
    )


# ---------------------------------------------------------------------------
# Test 2: successful JSON (successCount > 0) does NOT raise
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_edit_success_json_does_not_raise(acli: ModuleType) -> None:
    """When successCount > 0 and no FAILURE results, no exception is raised."""
    success_stdout = json.dumps(
        {
            "results": [{"status": "SUCCESS", "id": "DIG-1234"}],
            "totalCount": 1,
            "successCount": 1,
        }
    )
    mock_result = MagicMock(returncode=0, stdout=success_stdout, stderr="")

    with patch("subprocess.run", return_value=mock_result):
        # Should not raise. update_issue returns the parsed stdout.
        result = acli.update_issue("DIG-1234", summary="new title")
    assert result.get("successCount") == 1


# ---------------------------------------------------------------------------
# Test 3: non-JSON stdout falls back to exit-code check (no spurious raise)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_non_json_stdout_no_spurious_failure(acli: ModuleType) -> None:
    """Legacy / non-JSON stdout (e.g., scalar response, empty) must not be
    misinterpreted as a mutation failure. Falls back to exit-code semantics."""
    # add_comment uses --json and returns a single comment dict (not the
    # results[]/successCount shape). Must not raise AcliMutationError.
    comment_stdout = json.dumps({"id": "10001", "body": "hello"})
    mock_result = MagicMock(returncode=0, stdout=comment_stdout, stderr="")
    with patch("subprocess.run", return_value=mock_result):
        result = acli.add_comment("DIG-1234", "hello")
    assert result == {"id": "10001", "body": "hello"}


# ---------------------------------------------------------------------------
# Test 4: any results[].status == "FAILURE" raises (even if successCount > 0)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_mixed_results_with_failure_raises(acli: ModuleType) -> None:
    """Partial-failure shape (one FAILURE among successes) must raise so the
    reconciler can detect partial divergence rather than mark everything applied."""
    mixed_stdout = json.dumps(
        {
            "results": [
                {"status": "SUCCESS", "id": "DIG-1"},
                {
                    "status": "FAILURE",
                    "message": "transition not allowed",
                    "id": "DIG-2",
                },
            ],
            "totalCount": 2,
            "successCount": 1,
        }
    )
    mock_result = MagicMock(returncode=0, stdout=mixed_stdout, stderr="")
    with (
        patch("subprocess.run", return_value=mock_result),
        pytest.raises(acli.AcliMutationError),
    ):
        acli.update_issue("DIG-2", summary="x")


# ---------------------------------------------------------------------------
# Test 5: exit != 0 still raises CalledProcessError (existing contract preserved)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_non_zero_exit_still_raises_called_process_error(acli: ModuleType) -> None:
    """When ACLI exits non-zero, the existing CalledProcessError flow remains —
    AcliMutationError is only the exit=0-but-failure path."""
    exc = subprocess.CalledProcessError(
        returncode=1, cmd=["acli"], output="", stderr="boom"
    )
    with (
        patch("subprocess.run", side_effect=exc),
        pytest.raises(subprocess.CalledProcessError),
    ):
        acli.update_issue("DIG-1", summary="x")


# ---------------------------------------------------------------------------
# Test 6: AcliMutationError is a RuntimeError subclass (caller-friendly)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_mutation_error_is_runtime_error(acli: ModuleType) -> None:
    """AcliMutationError must subclass RuntimeError so callers catching
    RuntimeError (or BaseException) handle it correctly."""
    assert issubclass(acli.AcliMutationError, RuntimeError)


# ---------------------------------------------------------------------------
# Test 7: add_label silent-failure detection (uses --from-json path)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_add_label_failure_raises(acli: ModuleType) -> None:
    """add_label uses --from-json edit; mutation failures must surface."""
    failure_stdout = json.dumps(
        {
            "results": [
                {
                    "status": "FAILURE",
                    "message": "Issue does not exist",
                    "id": "DIG-99999",
                }
            ],
            "totalCount": 1,
            "successCount": 0,
        }
    )
    mock_result = MagicMock(returncode=0, stdout=failure_stdout, stderr="")
    client = acli.AcliClient(jira_url="", user="", api_token="")
    with (
        patch("subprocess.run", return_value=mock_result),
        pytest.raises(acli.AcliMutationError),
    ):
        client.add_label("DIG-99999", "alpha")


# ---------------------------------------------------------------------------
# Test 8: ensure --json flag is appended to label-edit commands
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_add_label_command_includes_json_flag(acli: ModuleType) -> None:
    """Label-edit commands must include --json so failure parsing can run."""
    success_stdout = json.dumps(
        {
            "results": [{"status": "SUCCESS", "id": "DIG-1"}],
            "totalCount": 1,
            "successCount": 1,
        }
    )
    mock_result = MagicMock(returncode=0, stdout=success_stdout, stderr="")
    client = acli.AcliClient(jira_url="", user="", api_token="")
    with patch("subprocess.run", return_value=mock_result) as mock_run:
        client.add_label("DIG-1", "alpha")
    cmd = mock_run.call_args_list[0][0][0]
    assert "--json" in cmd, f"Expected --json in label-edit command, got: {cmd}"
