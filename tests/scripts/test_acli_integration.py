"""RED tests for acli-integration.py.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL before acli-integration.py is implemented.

The module is expected to expose:
    create_issue(project: str, issue_type: str, summary: str, **kwargs) -> dict
    update_issue(jira_key: str, **kwargs) -> dict
    get_issue(jira_key: str) -> dict

Contract:
  - create_issue calls ACLI via subprocess.run with the correct arguments.
  - update_issue includes the Jira key in the ACLI command arguments.
  - get_issue parses ACLI JSON output and returns a dict with expected fields.
  - On CalledProcessError, operations retry up to 2 times with exponential
    backoff delays of 2s, 4s (2**n for n in 1..2); 3 total calls: initial + 2 retries.
  - create_issue calls get_issue after creation to verify the issue exists
    before returning.
  - Auth failures (exit code 401) abort immediately without retrying.

Test: python3 -m pytest tests/scripts/test_acli_integration.py
All tests must return non-zero until acli-integration.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

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
    """Return the acli-integration module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"acli-integration.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Test 1: create_issue calls subprocess.run with correct ACLI arguments
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_calls_acli_subprocess(acli: ModuleType) -> None:
    """create_issue must invoke subprocess.run with ACLI create arguments."""
    created_response = json.dumps(
        {"key": "PROJ-42", "summary": "Add bridge", "status": "To Do"}
    )
    get_response = json.dumps(
        {"key": "PROJ-42", "summary": "Add bridge", "status": "To Do"}
    )

    mock_create = MagicMock(returncode=0, stdout=created_response, stderr="")
    mock_get = MagicMock(returncode=0, stdout=get_response, stderr="")

    with patch("subprocess.run", side_effect=[mock_create, mock_get]) as mock_run:
        result = acli.create_issue(
            project="PROJ",
            issue_type="Task",
            summary="Add bridge",
        )

    # First call must be the create command
    first_call_args = mock_run.call_args_list[0]
    cmd = first_call_args[0][0]
    assert any("create" in str(arg).lower() for arg in cmd), (
        f"Expected 'create' in ACLI command arguments, got: {cmd}"
    )
    assert any("PROJ" in str(arg) for arg in cmd), (
        f"Expected project key 'PROJ' in ACLI command arguments, got: {cmd}"
    )
    assert any("Add bridge" in str(arg) for arg in cmd), (
        f"Expected summary 'Add bridge' in ACLI command arguments, got: {cmd}"
    )
    assert result is not None, "create_issue must return a non-None result"


# ---------------------------------------------------------------------------
# Test 2: update_issue calls ACLI with the Jira key
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_update_issue_calls_acli_with_jira_key(acli: ModuleType) -> None:
    """update_issue must include the Jira key in the subprocess command."""
    update_response = json.dumps({"key": "PROJ-99", "status": "In Progress"})
    mock_proc = MagicMock(returncode=0, stdout=update_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        result = acli.update_issue(
            jira_key="PROJ-99",
            status="In Progress",
        )

    assert mock_run.called, "subprocess.run must be called by update_issue"
    cmd = mock_run.call_args[0][0]
    assert any("PROJ-99" in str(arg) for arg in cmd), (
        f"Expected Jira key 'PROJ-99' in ACLI command arguments, got: {cmd}"
    )
    assert result is not None, "update_issue must return a non-None result"


# ---------------------------------------------------------------------------
# Test 3: get_issue returns parsed JSON output with expected fields
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_returns_parsed_json_output(acli: ModuleType) -> None:
    """get_issue must parse ACLI JSON output and return a dict with key/summary/status."""
    raw_output = json.dumps(
        {
            "key": "PROJ-7",
            "summary": "Implement outbound bridge",
            "status": "In Progress",
            "assignee": "dev@example.com",
        }
    )
    mock_proc = MagicMock(returncode=0, stdout=raw_output, stderr="")

    with patch("subprocess.run", return_value=mock_proc):
        result = acli.get_issue(jira_key="PROJ-7")

    assert isinstance(result, dict), f"get_issue must return a dict, got {type(result)}"
    assert result.get("key") == "PROJ-7", (
        f"Expected key='PROJ-7' in result, got: {result}"
    )
    assert "summary" in result, f"Expected 'summary' field in result, got: {result}"
    assert "status" in result, f"Expected 'status' field in result, got: {result}"


# ---------------------------------------------------------------------------
# Test 4: retry on subprocess.CalledProcessError — three attempts with backoff
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_retry_on_subprocess_error_three_attempts(acli: ModuleType) -> None:
    """On CalledProcessError, operations retry 2 times with 2s/4s backoff delays (3 total calls)."""
    error = subprocess.CalledProcessError(1, ["acli"])

    with (
        patch("subprocess.run", side_effect=error) as mock_run,
        patch("time.sleep") as mock_sleep,
    ):
        with pytest.raises((subprocess.CalledProcessError, Exception)):
            acli.get_issue(jira_key="PROJ-1")

    assert mock_run.call_count == 3, (
        f"Expected exactly 3 subprocess.run calls (initial + 2 retries), "
        f"got {mock_run.call_count}"
    )
    sleep_calls = [c[0][0] for c in mock_sleep.call_args_list]
    assert len(sleep_calls) >= 2, (
        f"Expected at least 2 sleep calls between retries, got {len(sleep_calls)}"
    )
    assert sleep_calls[0] == 2, (
        f"Expected first backoff delay of 2s, got {sleep_calls[0]}"
    )
    assert sleep_calls[1] == 4, (
        f"Expected second backoff delay of 4s, got {sleep_calls[1]}"
    )


# ---------------------------------------------------------------------------
# Test 5: verify-after-create — create_issue calls get_issue before returning
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_verify_after_create_calls_get_issue(acli: ModuleType) -> None:
    """create_issue must call get_issue after creation to verify the new issue."""
    created_response = json.dumps({"key": "PROJ-55", "summary": "Verify me"})
    verified_response = json.dumps(
        {"key": "PROJ-55", "summary": "Verify me", "status": "To Do"}
    )

    mock_create = MagicMock(returncode=0, stdout=created_response, stderr="")
    mock_verify = MagicMock(returncode=0, stdout=verified_response, stderr="")

    with patch("subprocess.run", side_effect=[mock_create, mock_verify]) as mock_run:
        result = acli.create_issue(
            project="PROJ",
            issue_type="Story",
            summary="Verify me",
        )

    assert mock_run.call_count >= 2, (
        f"create_issue must call subprocess.run at least twice "
        f"(create + verify get), got {mock_run.call_count} call(s)"
    )
    # The second call must reference the created key for verification
    second_call_cmd = mock_run.call_args_list[1][0][0]
    assert any("PROJ-55" in str(arg) for arg in second_call_cmd), (
        f"Expected verify call to include Jira key 'PROJ-55', got: {second_call_cmd}"
    )
    assert result is not None, "create_issue must return a result after verification"


# ---------------------------------------------------------------------------
# Test 6 (bonus): auth failure fast-abort — no retry on 401-equivalent error
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_auth_failure_fast_abort(acli: ModuleType) -> None:
    """Auth failures (exit code 401) must abort immediately without retrying."""
    auth_error = subprocess.CalledProcessError(
        returncode=401, cmd=["acli"], output="", stderr="Unauthorized"
    )

    with (
        patch("subprocess.run", side_effect=auth_error) as mock_run,
        patch("time.sleep") as mock_sleep,
    ):
        with pytest.raises((subprocess.CalledProcessError, PermissionError, Exception)):
            acli.get_issue(jira_key="PROJ-2")

    assert mock_run.call_count == 1, (
        f"Auth failures must not be retried; expected 1 call, got {mock_run.call_count}"
    )
    assert mock_sleep.call_count == 0, (
        f"Auth failures must not trigger backoff sleep; got {mock_sleep.call_count} sleep call(s)"
    )
