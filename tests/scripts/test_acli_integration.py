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
