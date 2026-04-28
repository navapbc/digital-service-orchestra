"""RED tests for ACLI comment operations in acli-integration.py.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL before add_comment and get_comments are implemented
in acli-integration.py.

The module is expected to expose:
    add_comment(jira_key: str, body: str, acli_cmd=None) -> dict
    get_comments(jira_key: str, acli_cmd=None) -> list[dict]

Contract:
  - add_comment calls ACLI via subprocess with --action addComment, --issue <jira_key>,
    --comment <body>; returns dict with at minimum {id: str, body: str}.
  - add_comment passes the full body (including any <!-- origin-uuid: ... --> markers)
    to ACLI unchanged.
  - add_comment retries up to 2 times on transient CalledProcessError (non-401).
  - add_comment fast-aborts on exit code 401 without retrying.
  - get_comments calls ACLI via subprocess with --action getComments, --issue <jira_key>;
    returns list of dicts each with at minimum {id: str, body: str}.
  - get_comments returns an empty list when ACLI returns a JSON empty array.

Test: python3 -m pytest tests/scripts/test_acli_integration_comments.py
All tests must return non-zero until add_comment and get_comments are implemented.
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
# Test 1: add_comment calls ACLI addComment action with correct arguments
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_add_comment_calls_acli_addComment_action(acli: ModuleType) -> None:
    """add_comment must invoke ACLI with --action addComment, --issue, and --comment."""
    comment_response = json.dumps({"id": "10001", "body": "This is a comment"})
    mock_proc = MagicMock(returncode=0, stdout=comment_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        result = acli.add_comment(
            jira_key="PROJ-42",
            body="This is a comment",
        )

    assert mock_run.called, "subprocess.run must be called by add_comment"
    cmd = mock_run.call_args[0][0]
    # ACLI v2 uses subcommand syntax: acli jira workitem comment create
    # (v1 used --action addComment; tests updated to match current CLI shape)
    assert any("comment" in str(arg) for arg in cmd), (
        f"Expected 'comment' subcommand in ACLI command arguments, got: {cmd}"
    )
    assert any("create" in str(arg) for arg in cmd), (
        f"Expected 'create' subcommand in ACLI command arguments, got: {cmd}"
    )
    assert any("PROJ-42" in str(arg) for arg in cmd), (
        f"Expected 'PROJ-42' (jira key) in ACLI command arguments, got: {cmd}"
    )
    assert any("This is a comment" in str(arg) for arg in cmd), (
        f"Expected body text in ACLI command arguments, got: {cmd}"
    )
    assert isinstance(result, dict), (
        f"add_comment must return a dict, got {type(result)}"
    )
    assert "id" in result, f"Result dict must contain 'id' field, got: {result}"
    assert "body" in result, f"Result dict must contain 'body' field, got: {result}"


# ---------------------------------------------------------------------------
# Test 2: add_comment preserves full body including origin-uuid marker
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_add_comment_with_marker_preserves_full_body(acli: ModuleType) -> None:
    """add_comment must pass the full body including <!-- origin-uuid: ... --> marker to ACLI unchanged."""
    body_with_marker = "Sync note\n<!-- origin-uuid: abc-123-def-456 -->"
    comment_response = json.dumps({"id": "10002", "body": body_with_marker})
    mock_proc = MagicMock(returncode=0, stdout=comment_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        result = acli.add_comment(
            jira_key="PROJ-7",
            body=body_with_marker,
        )

    assert mock_run.called, "subprocess.run must be called by add_comment"
    cmd = mock_run.call_args[0][0]
    # The full body string (marker included) must appear as an argument
    assert any(body_with_marker in str(arg) for arg in cmd), (
        f"Expected full body with origin-uuid marker in ACLI command arguments, "
        f"got: {cmd}"
    )
    assert isinstance(result, dict), (
        f"add_comment must return a dict, got {type(result)}"
    )


# ---------------------------------------------------------------------------
# Test 3: add_comment retries on transient CalledProcessError (non-401)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_add_comment_retries_on_transient_failure(acli: ModuleType) -> None:
    """add_comment must retry on transient CalledProcessError and return on eventual success."""
    transient_error = subprocess.CalledProcessError(1, ["acli"])
    success_response = json.dumps({"id": "10003", "body": "Retry succeeded"})
    mock_success = MagicMock(returncode=0, stdout=success_response, stderr="")

    with (
        patch(
            "subprocess.run", side_effect=[transient_error, mock_success]
        ) as mock_run,
        patch("time.sleep"),
    ):
        result = acli.add_comment(
            jira_key="PROJ-10",
            body="Retry succeeded",
        )

    assert mock_run.call_count == 2, (
        f"Expected 2 subprocess.run calls (1 failure + 1 retry success), "
        f"got {mock_run.call_count}"
    )
    assert isinstance(result, dict), (
        f"add_comment must return a dict after successful retry, got {type(result)}"
    )
    assert result.get("id") == "10003", (
        f"Expected id='10003' from successful retry, got: {result}"
    )


# ---------------------------------------------------------------------------
# Test 4: add_comment fast-aborts on auth failure (exit code 401)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_add_comment_fast_aborts_on_auth_failure(acli: ModuleType) -> None:
    """add_comment must raise CalledProcessError immediately on exit code 401 without retrying."""
    auth_error = subprocess.CalledProcessError(
        returncode=401, cmd=["acli"], output="", stderr="Unauthorized"
    )

    with (
        patch("subprocess.run", side_effect=auth_error) as mock_run,
        patch("time.sleep") as mock_sleep,
    ):
        with pytest.raises(subprocess.CalledProcessError):
            acli.add_comment(
                jira_key="PROJ-99",
                body="Should not be posted",
            )

    assert mock_run.call_count == 1, (
        f"Auth failures must not be retried; expected 1 call, got {mock_run.call_count}"
    )
    assert mock_sleep.call_count == 0, (
        f"Auth failures must not trigger backoff sleep; "
        f"got {mock_sleep.call_count} sleep call(s)"
    )


# ---------------------------------------------------------------------------
# Test 5: get_comments calls ACLI getComments action with correct arguments
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_comments_calls_acli_getComments_action(acli: ModuleType) -> None:
    """get_comments must invoke ACLI with --action getComments and --issue <jira_key>."""
    comments_response = json.dumps(
        [
            {"id": "20001", "body": "First comment"},
            {"id": "20002", "body": "Second comment"},
        ]
    )
    mock_proc = MagicMock(returncode=0, stdout=comments_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc) as mock_run:
        result = acli.get_comments(jira_key="PROJ-55")

    assert mock_run.called, "subprocess.run must be called by get_comments"
    cmd = mock_run.call_args[0][0]
    # ACLI v2 uses subcommand syntax: acli jira workitem comment list
    # (v1 used --action getComments; tests updated to match current CLI shape)
    assert any("comment" in str(arg) for arg in cmd), (
        f"Expected 'comment' subcommand in ACLI command arguments, got: {cmd}"
    )
    assert any("list" in str(arg) for arg in cmd), (
        f"Expected 'list' subcommand in ACLI command arguments, got: {cmd}"
    )
    assert any("PROJ-55" in str(arg) for arg in cmd), (
        f"Expected '--issue PROJ-55' in ACLI command arguments, got: {cmd}"
    )
    assert isinstance(result, list), (
        f"get_comments must return a list, got {type(result)}"
    )
    assert len(result) == 2, f"Expected 2 comments in result, got {len(result)}"
    assert "id" in result[0], (
        f"Each comment dict must contain 'id' field, got: {result[0]}"
    )
    assert "body" in result[0], (
        f"Each comment dict must contain 'body' field, got: {result[0]}"
    )


# ---------------------------------------------------------------------------
# Test 6: get_comments returns empty list when no comments exist
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_comments_returns_empty_list_when_no_comments(acli: ModuleType) -> None:
    """get_comments must return an empty list when ACLI returns a JSON empty array."""
    empty_response = json.dumps([])
    mock_proc = MagicMock(returncode=0, stdout=empty_response, stderr="")

    with patch("subprocess.run", return_value=mock_proc):
        result = acli.get_comments(jira_key="PROJ-100")

    assert isinstance(result, list), (
        f"get_comments must return a list, got {type(result)}"
    )
    assert len(result) == 0, (
        f"get_comments must return an empty list when ACLI returns [], "
        f"got {len(result)} item(s): {result}"
    )
