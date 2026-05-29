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
        # Should not raise. update_issue returns the parsed-JSON dict
        # (json.loads(result.stdout)) — not the CompletedProcess itself.
        result = acli.update_issue("DIG-1234", summary="new title")
    assert isinstance(result, dict), (
        f"update_issue must return parsed JSON dict, got {type(result).__name__}"
    )
    assert result.get("successCount") == 1
    assert result.get("results") == [{"status": "SUCCESS", "id": "DIG-1234"}]


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


# ---------------------------------------------------------------------------
# Test 9: delete_issue routes through _check_mutation_failure (bypass guard)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_failure_raises(acli: ModuleType) -> None:
    """delete_issue uses a raw subprocess.run path (not _run_acli) but must
    still invoke _check_mutation_failure so exit=0 + FAILURE-shape stdout
    raises AcliMutationError. Without this, a failed delete on a non-existent
    or unpermitted issue would be silently marked as success."""
    failure_stdout = json.dumps(
        {
            "results": [
                {
                    "status": "FAILURE",
                    "message": "Issue does not exist or you do not have permission",
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
        client.delete_issue("DIG-99999")


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_command_includes_json_flag(acli: ModuleType) -> None:
    """delete_issue must pass --json so the structured-failure check can run."""
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
        client.delete_issue("DIG-1")
    cmd = mock_run.call_args_list[0][0][0]
    assert "--json" in cmd, f"Expected --json in delete command, got: {cmd}"


# ---------------------------------------------------------------------------
# Test 10: delete_issue_link routes through _run_acli (mutation detection)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_issue_link_failure_raises(acli: ModuleType) -> None:
    """delete_issue_link goes through _run_acli (via self._run); a failed
    link delete with exit=0 + FAILURE stdout must raise AcliMutationError."""
    failure_stdout = json.dumps(
        {
            "results": [
                {
                    "status": "FAILURE",
                    "message": "Link does not exist",
                    "id": "10001",
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
        client.delete_issue_link("10001")


# ---------------------------------------------------------------------------
# Tests 11–14: _check_mutation_failure edge cases (early-return safety)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_check_mutation_failure_none_stdout_no_raise(acli: ModuleType) -> None:
    """None stdout must early-return without raising or crashing."""
    # Should be a silent no-op — no signal to interpret.
    acli._check_mutation_failure(None, ["acli", "jira", "workitem", "edit"])  # type: ignore[arg-type]


@pytest.mark.unit
@pytest.mark.scripts
def test_check_mutation_failure_empty_stdout_no_raise(acli: ModuleType) -> None:
    """Empty / whitespace-only stdout must early-return — falls back to
    exit-code semantics enforced by subprocess.run(check=True)."""
    acli._check_mutation_failure("", ["acli", "jira", "workitem", "edit"])
    acli._check_mutation_failure("   \n  ", ["acli", "jira", "workitem", "edit"])


@pytest.mark.unit
@pytest.mark.scripts
def test_check_mutation_failure_invalid_json_no_raise(acli: ModuleType) -> None:
    """Non-JSON stdout (legacy text response) must not raise — defers to the
    exit-code contract rather than crashing on a JSON parse error."""
    acli._check_mutation_failure(
        "not json at all <html>error</html>",
        ["acli", "jira", "workitem", "edit"],
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_check_mutation_failure_non_dict_json_no_raise(acli: ModuleType) -> None:
    """List-shaped JSON (e.g., search/get results) lacks the mutation
    successCount/results envelope and must early-return without raising."""
    acli._check_mutation_failure(
        json.dumps([{"id": "DIG-1"}, {"id": "DIG-2"}]),
        ["acli", "jira", "workitem", "search"],
    )
    # Scalar JSON value too.
    acli._check_mutation_failure(
        json.dumps("plain string"),
        ["acli", "jira", "workitem", "search"],
    )
