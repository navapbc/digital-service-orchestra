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
import logging
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


# ---------------------------------------------------------------------------
# Test 7: AcliClient has outbound methods (create_issue, update_issue, get_issue, add_comment)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_client_has_outbound_methods(acli: ModuleType) -> None:
    """AcliClient must expose create_issue, update_issue, get_issue, add_comment
    methods for the outbound bridge contract."""
    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    assert hasattr(client, "create_issue"), "AcliClient must have create_issue method"
    assert hasattr(client, "update_issue"), "AcliClient must have update_issue method"
    assert hasattr(client, "get_issue"), "AcliClient must have get_issue method"
    assert hasattr(client, "add_comment"), "AcliClient must have add_comment method"
    assert callable(client.create_issue)
    assert callable(client.update_issue)
    assert callable(client.get_issue)
    assert callable(client.add_comment)


# ---------------------------------------------------------------------------
# Test 8: AcliClient.create_issue accepts ticket_data dict and uses jira_project
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_client_create_issue_uses_ticket_data(acli: ModuleType) -> None:
    """AcliClient.create_issue(ticket_data) must extract type and title from the
    dict and use the client's jira_project for the project parameter."""
    created_response = json.dumps({"key": "DSO-42", "summary": "Test ticket"})
    verified_response = json.dumps(
        {"key": "DSO-42", "summary": "Test ticket", "status": "To Do"}
    )
    mock_create = MagicMock(returncode=0, stdout=created_response, stderr="")
    mock_verify = MagicMock(returncode=0, stdout=verified_response, stderr="")

    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    ticket_data = {
        "ticket_type": "task",
        "title": "Test ticket",
    }

    with patch("subprocess.run", side_effect=[mock_create, mock_verify]) as mock_run:
        result = client.create_issue(ticket_data)

    assert result is not None
    assert result.get("key") == "DSO-42"
    # The ACLI create command must include the project from the client
    first_call_cmd = mock_run.call_args_list[0][0][0]
    assert any("DSO" in str(arg) for arg in first_call_cmd), (
        f"Expected project 'DSO' in ACLI command, got: {first_call_cmd}"
    )
    assert any("Test ticket" in str(arg) for arg in first_call_cmd), (
        f"Expected title 'Test ticket' in ACLI command, got: {first_call_cmd}"
    )


# ---------------------------------------------------------------------------
# Test 9: AcliClient.update_issue delegates with jira_key and kwargs
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_client_update_issue_delegates(acli: ModuleType) -> None:
    """AcliClient.update_issue(jira_key, status=...) must call ACLI edit."""
    update_response = json.dumps({"key": "DSO-42", "status": "In Progress"})
    mock_proc = MagicMock(returncode=0, stdout=update_response, stderr="")

    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        result = client.update_issue("DSO-42", status="In Progress")

    assert result is not None
    cmd = mock_run.call_args[0][0]
    assert any("DSO-42" in str(arg) for arg in cmd)


# ---------------------------------------------------------------------------
# Test 10: AcliClient.get_issue delegates
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_client_get_issue_delegates(acli: ModuleType) -> None:
    """AcliClient.get_issue(jira_key) must call ACLI view and return parsed JSON."""
    view_response = json.dumps({"key": "DSO-42", "status": "Open"})
    mock_proc = MagicMock(returncode=0, stdout=view_response, stderr="")

    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    with patch("subprocess.run", return_value=mock_proc):
        result = client.get_issue("DSO-42")

    assert isinstance(result, dict)
    assert result.get("key") == "DSO-42"


# ---------------------------------------------------------------------------
# Test 11: AcliClient.add_comment delegates
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_client_add_comment_delegates(acli: ModuleType) -> None:
    """AcliClient.add_comment(jira_key, body) must call ACLI comment create."""
    comment_response = json.dumps({"id": "10042", "body": "Hello"})
    mock_proc = MagicMock(returncode=0, stdout=comment_response, stderr="")

    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        result = client.add_comment("DSO-42", "Hello")

    assert result is not None
    cmd = mock_run.call_args[0][0]
    assert any("DSO-42" in str(arg) for arg in cmd)
    assert any("Hello" in str(arg) for arg in cmd)


# ---------------------------------------------------------------------------
# Test 12: create_issue with priority routes through _create_issue_from_json
#          and includes summary in the JSON payload
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_from_json_forwards_summary(acli: ModuleType) -> None:
    """create_issue with priority must route through _create_issue_from_json
    and include the summary field in the JSON payload written to disk."""
    created_response = json.dumps({"key": "PROJ-99", "summary": "My summary"})
    verified_response = json.dumps(
        {"key": "PROJ-99", "summary": "My summary", "status": "To Do"}
    )

    captured_payloads: list[dict] = []

    def capturing_run(cmd: list[str], **kwargs: object) -> MagicMock:
        """Intercept subprocess.run to read the temp JSON file before it's deleted."""
        # The create call uses --from-json <path>; read the payload while it exists
        if "--from-json" in cmd:
            idx = cmd.index("--from-json") + 1
            json_path = cmd[idx]
            with open(json_path) as f:
                captured_payloads.append(json.load(f))
            return MagicMock(returncode=0, stdout=created_response, stderr="")
        # The verify-after-create call (get_issue)
        return MagicMock(returncode=0, stdout=verified_response, stderr="")

    with patch("subprocess.run", side_effect=capturing_run):
        result = acli.create_issue(
            project="PROJ",
            issue_type="Task",
            summary="My summary",
            priority=2,
        )

    assert result is not None
    assert result.get("key") == "PROJ-99"

    # Verify the --from-json path was taken and the payload contains summary
    assert len(captured_payloads) == 1, (
        "Expected exactly one --from-json call when priority is set"
    )
    payload = captured_payloads[0]
    assert payload.get("summary") == "My summary", (
        f"Expected summary 'My summary' in JSON payload, got: {payload}"
    )


# ---------------------------------------------------------------------------
# Test 13 (RED): _text_to_adf returns a valid ADF document structure
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_text_to_adf_returns_valid_adf_structure(acli: ModuleType) -> None:
    """_text_to_adf(text) must return an ADF dict with type='doc', version=1,
    and a paragraph content node containing the original text."""
    assert hasattr(acli, "_text_to_adf"), (
        "_text_to_adf function not found in acli-integration.py — "
        "implement _text_to_adf to convert plain text to Atlassian Document Format"
    )

    result = acli._text_to_adf("Hello, Jira!")

    assert isinstance(result, dict), (
        f"_text_to_adf must return a dict (ADF object), got {type(result)}"
    )
    assert result.get("type") == "doc", (
        f"ADF root must have type='doc', got type={result.get('type')!r}"
    )
    assert result.get("version") == 1, (
        f"ADF root must have version=1, got version={result.get('version')!r}"
    )
    content = result.get("content")
    assert isinstance(content, list) and len(content) >= 1, (
        f"ADF root must have a non-empty 'content' list, got: {content!r}"
    )
    paragraph = content[0]
    assert paragraph.get("type") == "paragraph", (
        f"First content node must have type='paragraph', got: {paragraph.get('type')!r}"
    )
    inner_content = paragraph.get("content")
    assert isinstance(inner_content, list) and len(inner_content) >= 1, (
        f"Paragraph must have a non-empty 'content' list, got: {inner_content!r}"
    )
    text_node = inner_content[0]
    assert text_node.get("type") == "text", (
        f"First paragraph content node must have type='text', got: {text_node.get('type')!r}"
    )
    assert text_node.get("text") == "Hello, Jira!", (
        f"Text node must preserve original string, got: {text_node.get('text')!r}"
    )


# ---------------------------------------------------------------------------
# Test 14 (RED): _create_issue_from_json sends description as ADF object
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_from_json_sends_description_as_adf(acli: ModuleType) -> None:
    """When description is provided, _create_issue_from_json must write an ADF
    object (not a plain string) into the JSON payload's 'description' field."""
    created_response = json.dumps({"key": "PROJ-77", "summary": "ADF test"})
    verified_response = json.dumps(
        {"key": "PROJ-77", "summary": "ADF test", "status": "To Do"}
    )

    captured_payloads: list[dict] = []

    def capturing_run(cmd: list[str], **kwargs: object) -> MagicMock:
        if "--from-json" in cmd:
            idx = cmd.index("--from-json") + 1
            json_path = cmd[idx]
            with open(json_path) as f:
                captured_payloads.append(json.load(f))
            return MagicMock(returncode=0, stdout=created_response, stderr="")
        return MagicMock(returncode=0, stdout=verified_response, stderr="")

    with patch("subprocess.run", side_effect=capturing_run):
        acli.create_issue(
            project="PROJ",
            issue_type="Task",
            summary="ADF test",
            priority=2,
            description="Fix the outbound bridge",
        )

    assert len(captured_payloads) == 1, (
        "Expected exactly one --from-json call when priority is set"
    )
    payload = captured_payloads[0]
    assert "description" in payload, (
        f"Expected 'description' key in JSON payload, got keys: {list(payload.keys())}"
    )
    description = payload["description"]
    assert isinstance(description, dict), (
        f"description in JSON payload must be an ADF dict (not a plain string), "
        f"got {type(description).__name__!r}: {description!r}"
    )
    assert description.get("type") == "doc", (
        f"description ADF object must have type='doc', got: {description.get('type')!r}"
    )
    assert description.get("version") == 1, (
        f"description ADF object must have version=1, got: {description.get('version')!r}"
    )


# ---------------------------------------------------------------------------
# Test 15 (RED): transition_issue passes Jira-formatted status names to ACLI
#
# BUG dfcd-4266: status.capitalize() produces "In_progress" not "In Progress".
# After the fix (_LOCAL_STATUS_TO_JIRA mapping), all three statuses must map
# to the correct Jira workflow state names.
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_transition_issue_maps_in_progress_to_jira_name(acli: ModuleType) -> None:
    """transition_issue("in_progress") must pass "In Progress" to ACLI, not "In_progress".

    The current code uses status.capitalize() which produces "In_progress" for
    snake_case inputs. The fix must add a _LOCAL_STATUS_TO_JIRA mapping dict so
    that "in_progress" -> "In Progress".
    """
    transition_response = '{"key": "PROJ-1", "status": "In Progress"}'
    mock_proc = MagicMock(returncode=0, stdout=transition_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        acli.transition_issue(jira_key="PROJ-1", status="in_progress")

    assert mock_run.called, "subprocess.run must be called by transition_issue"
    cmd = mock_run.call_args[0][0]

    # Find the value passed after the --status flag in the ACLI command
    status_value = None
    for i, arg in enumerate(cmd):
        if arg == "--status" and i + 1 < len(cmd):
            status_value = cmd[i + 1]
            break

    assert status_value is not None, (
        f"Expected --status flag in ACLI command, got: {cmd}"
    )
    assert status_value == "In Progress", (
        f"transition_issue('in_progress') must pass 'In Progress' to ACLI, "
        f"but got {status_value!r}. "
        f"This fails because status.capitalize() produces 'In_progress' — "
        f"fix by adding a _LOCAL_STATUS_TO_JIRA mapping dict."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_transition_issue_maps_open_to_jira_name(acli: ModuleType) -> None:
    """transition_issue("open") must pass "To Do" to ACLI, not "Open".

    Local status "open" corresponds to Jira workflow state "To Do".
    """
    transition_response = '{"key": "PROJ-2", "status": "To Do"}'
    mock_proc = MagicMock(returncode=0, stdout=transition_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        acli.transition_issue(jira_key="PROJ-2", status="open")

    assert mock_run.called, "subprocess.run must be called by transition_issue"
    cmd = mock_run.call_args[0][0]

    status_value = None
    for i, arg in enumerate(cmd):
        if arg == "--status" and i + 1 < len(cmd):
            status_value = cmd[i + 1]
            break

    assert status_value is not None, (
        f"Expected --status flag in ACLI command, got: {cmd}"
    )
    assert status_value == "To Do", (
        f"transition_issue('open') must pass 'To Do' to ACLI, "
        f"but got {status_value!r}. "
        f"Fix by adding 'open' -> 'To Do' to the _LOCAL_STATUS_TO_JIRA mapping."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_transition_issue_maps_closed_to_jira_name(acli: ModuleType) -> None:
    """transition_issue("closed") must pass "Done" to ACLI, not "Closed".

    Local status "closed" corresponds to Jira workflow state "Done".
    """
    transition_response = '{"key": "PROJ-3", "status": "Done"}'
    mock_proc = MagicMock(returncode=0, stdout=transition_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        acli.transition_issue(jira_key="PROJ-3", status="closed")

    assert mock_run.called, "subprocess.run must be called by transition_issue"
    cmd = mock_run.call_args[0][0]

    status_value = None
    for i, arg in enumerate(cmd):
        if arg == "--status" and i + 1 < len(cmd):
            status_value = cmd[i + 1]
            break

    assert status_value is not None, (
        f"Expected --status flag in ACLI command, got: {cmd}"
    )
    assert status_value == "Done", (
        f"transition_issue('closed') must pass 'Done' to ACLI, "
        f"but got {status_value!r}. "
        f"Fix by adding 'closed' -> 'Done' to the _LOCAL_STATUS_TO_JIRA mapping."
    )


# ---------------------------------------------------------------------------
# Test 16: create_issue retries without assignee on permission error
#
# BUG 7812-8682: When ACLI returns "cannot be assigned issues" for the
# assignee field, the entire create_issue call crashes instead of retrying
# without the assignee.  The fix must catch this specific error and retry
# the creation with the assignee field removed from the payload.
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_retries_without_assignee_on_permission_error(
    acli: ModuleType,
) -> None:
    """create_issue must retry without assignee when ACLI reports
    'cannot be assigned issues', and the second attempt must succeed."""
    created_response = json.dumps({"key": "PROJ-42", "summary": "Retry test"})
    verified_response = json.dumps(
        {"key": "PROJ-42", "summary": "Retry test", "status": "To Do"}
    )

    captured_payloads: list[dict] = []

    def capturing_run(cmd: list[str], **kwargs: object) -> MagicMock:
        if "--from-json" in cmd:
            idx = cmd.index("--from-json") + 1
            json_path = cmd[idx]
            with open(json_path) as f:
                payload = json.load(f)
            captured_payloads.append(payload)

            # Any attempt with assignee present: fail with permission error
            if payload.get("assignee"):
                raise subprocess.CalledProcessError(
                    1,
                    cmd,
                    output="",
                    stderr="✗ Error: User '712020:fake-id' cannot be assigned issues.",
                )
            # Attempt without assignee: succeed
            return MagicMock(returncode=0, stdout=created_response, stderr="")
        # get_issue verification call
        return MagicMock(returncode=0, stdout=verified_response, stderr="")

    with (
        patch("subprocess.run", side_effect=capturing_run),
        patch("time.sleep"),  # skip _run_acli retry delays
    ):
        result = acli.create_issue(
            project="PROJ",
            issue_type="Task",
            summary="Retry test",
            priority=2,
            assignee="some-user",
        )

    assert result is not None, "create_issue must return a result after retry"
    assert result.get("key") == "PROJ-42"

    # Deduplicate payloads (since _run_acli retries with the same payload)
    unique_payloads: list[dict] = []
    for p in captured_payloads:
        if not unique_payloads or p != unique_payloads[-1]:
            unique_payloads.append(p)

    # Must have at least two distinct payload shapes
    assert len(unique_payloads) >= 2, (
        f"Expected at least 2 distinct --from-json payloads (with then without assignee), "
        f"got {len(unique_payloads)}. "
        f"Fix _create_issue_from_json to catch 'cannot be assigned' errors and "
        f"retry without the assignee field."
    )

    # Second distinct payload must NOT contain assignee
    retry_payload = unique_payloads[1]
    assert "assignee" not in retry_payload, (
        f"Retry payload must not contain 'assignee', but got: {retry_payload}. "
        f"Fix _create_issue_from_json to remove assignee from the payload on retry."
    )


# ---------------------------------------------------------------------------
# Test 17: create_issue (non-JSON path) retries without assignee on permission error
#
# Tests the code path where create_issue is called WITH an assignee but WITHOUT
# priority (so the non-JSON ACLI command path is taken, not --from-json).
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_no_priority_retries_without_assignee_on_permission_error(
    acli: ModuleType,
) -> None:
    """create_issue without priority must retry without assignee when ACLI
    reports 'cannot be assigned issues', and the second attempt must succeed."""
    created_response = json.dumps({"key": "PROJ-50", "summary": "No-priority retry"})
    verified_response = json.dumps(
        {"key": "PROJ-50", "summary": "No-priority retry", "status": "To Do"}
    )

    create_cmds: list[list[str]] = []

    def mock_run(cmd: list[str], **kwargs: object) -> MagicMock:
        # Detect verify-after-create call (get_issue uses "get" action)
        if "create" not in cmd:
            return MagicMock(returncode=0, stdout=verified_response, stderr="")

        create_cmds.append(list(cmd))

        # Any create attempt with --assignee → fail with permission error
        if "--assignee" in cmd:
            raise subprocess.CalledProcessError(
                1,
                cmd,
                output="",
                stderr="✗ Error: User 'abc123' cannot be assigned issues.",
            )

        # Retry without assignee → succeed
        return MagicMock(returncode=0, stdout=created_response, stderr="")

    with (
        patch("subprocess.run", side_effect=mock_run),
        patch("time.sleep"),  # skip _run_acli retry delays
    ):
        result = acli.create_issue(
            project="PROJ",
            issue_type="Task",
            summary="No-priority retry",
            assignee="abc123",
            # No priority — takes the non-JSON path
        )

    assert result is not None, "create_issue must return a result after retry"
    assert result.get("key") == "PROJ-50", (
        f"Expected key 'PROJ-50', got: {result.get('key')}"
    )

    # Must have at least one create with assignee and one without
    with_assignee = [c for c in create_cmds if "--assignee" in c]
    without_assignee = [c for c in create_cmds if "--assignee" not in c]
    assert len(with_assignee) >= 1, (
        f"Expected at least one create attempt with --assignee, got commands: {create_cmds}"
    )
    assert len(without_assignee) >= 1, (
        f"Expected at least one retry without --assignee, got commands: {create_cmds}. "
        f"Ensure the non-JSON path retries without assignee on permission error."
    )


# ---------------------------------------------------------------------------
# Test 18: create_issue raises RuntimeError when retry-without-assignee also fails
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_raises_when_retry_without_assignee_also_fails(
    acli: ModuleType,
) -> None:
    """When both the initial create (with assignee) AND the retry (without
    assignee) fail with 'cannot be assigned', create_issue must raise
    RuntimeError rather than silently returning None."""

    captured_payloads: list[dict] = []

    def always_fail_run(cmd: list[str], **kwargs: object) -> MagicMock:
        if "--from-json" in cmd:
            idx = cmd.index("--from-json") + 1
            json_path = cmd[idx]
            with open(json_path) as f:
                payload = json.load(f)
            captured_payloads.append(payload)
            # Both attempts fail with the permission error
            raise subprocess.CalledProcessError(
                1,
                cmd,
                output="",
                stderr="✗ Error: User 'fake-id' cannot be assigned issues.",
            )
        # get_issue call — should never be reached
        return MagicMock(returncode=0, stdout="{}", stderr="")

    with (
        patch("subprocess.run", side_effect=always_fail_run),
        patch("time.sleep"),
        pytest.raises(RuntimeError, match="retry without assignee"),
    ):
        acli.create_issue(
            project="PROJ",
            issue_type="Task",
            summary="Double fail",
            priority=2,
            assignee="some-user",
        )

    # Should have attempted with assignee, then without
    assert len(captured_payloads) >= 2, (
        f"Expected at least 2 payloads (with then without assignee), "
        f"got {len(captured_payloads)}"
    )


# ---------------------------------------------------------------------------
# Test 19: AcliClient.create_issue raises ValueError on empty title
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_acli_client_create_issue_rejects_empty_title(acli: ModuleType) -> None:
    """AcliClient.create_issue must raise ValueError when ticket_data has
    an empty or whitespace-only title, rather than passing an empty --summary
    to ACLI which causes CalledProcessError."""
    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    for empty_title in ["", "   ", None]:
        ticket_data = {"ticket_type": "task", "title": empty_title}
        if empty_title is None:
            ticket_data = {"ticket_type": "task"}  # missing title key
        with pytest.raises(
            ValueError, match="(?i)summary.*empty|title.*empty|empty.*title"
        ):
            client.create_issue(ticket_data)


# ---------------------------------------------------------------------------
# Test 20 (RED): AcliClient.search_issues emits a WARNING when the JSON
# response is neither a bare list nor a dict with an "issues" key.
#
# BUG 0e38-a5da: the else branch silently returns [] with no log entry,
# causing 7+ days of zero syncs with no observable signal.
# After the fix, a logging.warning() call will be added to the else branch.
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_search_issues_warns_on_unrecognised_json_shape(acli: ModuleType) -> None:
    """AcliClient.search_issues must emit a WARNING when the ACLI JSON response
    is a dict that has no 'issues' key (e.g. {"total": 5, "maxResults": 50}).

    Given: ACLI returns a JSON dict without an "issues" key
    When:  search_issues is called with any JQL
    Then:  a WARNING-level log entry is emitted (observable side-effect)

    The current code hits `else: all_issues = []` with no warning, so
    assertLogs raises AssertionError ("no logs") — the test is RED.
    Adding `logging.warning(...)` to that branch makes the test GREEN.
    """
    import unittest

    client = acli.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="DSO",
    )

    # A dict with no "issues" key — the unrecognised shape that triggers the else branch
    unrecognised_response = json.dumps({"total": 5, "maxResults": 50})
    mock_proc = MagicMock(returncode=0, stdout=unrecognised_response, stderr="")

    tc = unittest.TestCase()
    tc.maxDiff = None

    with patch("subprocess.run", return_value=mock_proc):
        # assertLogs raises AssertionError if no WARNING is emitted —
        # this is the RED assertion: the current code emits nothing, so this FAILS.
        # After the fix adds logging.warning(...) to the else branch, it PASSES.
        with tc.assertLogs(level=logging.WARNING) as log_ctx:
            result = client.search_issues(jql="project = DSO")

    # The call must still return an empty list (existing contract preserved)
    assert result == [], (
        f"search_issues must return [] for unrecognised JSON shape, got: {result!r}"
    )

    # The warning must reference the unexpected shape in some way
    assert any(
        any(
            keyword in record.lower()
            for keyword in (
                "issues",
                "unexpected",
                "unrecognised",
                "unrecognized",
                "shape",
                "format",
                "neither",
                "unknown",
                "parse",
            )
        )
        for record in log_ctx.output
    ), (
        f"Expected a warning mentioning the unexpected JSON shape, "
        f"but got: {log_ctx.output}"
    )


# ---------------------------------------------------------------------------
# Test 19: AcliClient.get_myself() — HTTP success, error fallback, caching
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_myself_returns_profile_on_success(acli: ModuleType) -> None:
    """AcliClient.get_myself() must return parsed JSON from /rest/api/2/myself
    and cache the result so a second call does not make a new HTTP request.

    Given: urllib.request.urlopen returns {"timeZone": "America/Los_Angeles"}
    When:  get_myself() is called twice
    Then:  first call returns the profile dict; second call returns same dict
           without a second HTTP call (cache hit).
    """
    import json as _json
    import urllib.request
    from unittest.mock import patch

    profile = {"timeZone": "America/Los_Angeles", "accountId": "abc123"}
    body = _json.dumps(profile).encode("utf-8")

    class _FakeResponse:
        def read(self) -> bytes:
            return body

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

    client = acli.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
        jira_project="PROJ",
    )

    with patch.object(
        urllib.request, "urlopen", return_value=_FakeResponse()
    ) as mock_urlopen:
        result1 = client.get_myself()
        result2 = client.get_myself()

    assert result1 == profile, f"Expected {profile!r}, got {result1!r}"
    assert result2 == profile, f"Second call must return cached result, got {result2!r}"
    assert mock_urlopen.call_count == 1, (
        f"urlopen must be called once (cache hit on second call); "
        f"called {mock_urlopen.call_count} times"
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_get_myself_returns_empty_dict_on_url_error(acli: ModuleType) -> None:
    """AcliClient.get_myself() must return {{}} and log a warning when
    urllib.request.urlopen raises URLError (network failure or auth error).

    Given: urlopen raises urllib.error.URLError("connection refused")
    When:  get_myself() is called
    Then:  returns {{}} without raising, and emits a warning log.
    """
    import urllib.error
    import urllib.request
    from unittest.mock import patch

    client = acli.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
        jira_project="PROJ",
    )

    with patch.object(
        urllib.request,
        "urlopen",
        side_effect=urllib.error.URLError("connection refused"),
    ):
        result = client.get_myself()

    assert result == {}, f"Expected {{}} on URLError, got {result!r}"


@pytest.mark.unit
@pytest.mark.scripts
def test_get_myself_returns_empty_dict_on_json_decode_error(acli: ModuleType) -> None:
    """AcliClient.get_myself() must return {{}} when the response body is not valid JSON.

    Given: urlopen returns a response with malformed JSON body
    When:  get_myself() is called
    Then:  returns {{}} without raising and emits a warning log.
    """
    import urllib.request
    from unittest.mock import patch

    class _BadResponse:
        def read(self) -> bytes:
            return b"not-json-{{"

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

    client = acli.AcliClient(
        jira_url="https://example.atlassian.net",
        user="user@example.com",
        api_token="token",
        jira_project="PROJ",
    )

    with patch.object(urllib.request, "urlopen", return_value=_BadResponse()):
        result = client.get_myself()

    assert result == {}, f"Expected {{}} on JSONDecodeError, got {result!r}"
