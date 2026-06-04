"""Tests for ACLI field-parity methods: priority edit, issuetype edit,
comment update/delete, get_issue search fallback, and rate-limit backoff.

Test: python3 -m pytest tests/scripts/test_acli_integration_new_methods.py
"""

from __future__ import annotations

import importlib.util
import json
import urllib.error
from io import BytesIO
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
    if not SCRIPT_PATH.exists():
        pytest.fail(f"acli-integration.py not found at {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_client(acli_mod: ModuleType) -> object:
    """Create an AcliClient with dummy credentials."""
    return acli_mod.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="TEST",
    )


# ---------------------------------------------------------------------------
# 1. update_priority calls REST PUT with correct payload
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_update_priority_calls_rest_put_with_correct_payload(acli: ModuleType) -> None:
    """AcliClient.update_priority sends PUT /rest/api/3/issue/{key}
    with {"fields":{"priority":{"name":"Highest"}}}."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_put_raw") as mock_put:
        client.update_priority("TEST-123", "Highest")
        mock_put.assert_called_once_with(
            "/rest/api/3/issue/TEST-123",
            {"fields": {"priority": {"name": "Highest"}}},
        )


# ---------------------------------------------------------------------------
# 2. update_issuetype calls REST PUT with correct payload
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_update_issuetype_calls_rest_put_with_correct_payload(acli: ModuleType) -> None:
    """AcliClient.update_issuetype sends PUT /rest/api/3/issue/{key}
    with {"fields":{"issuetype":{"name":"Story"}}}."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_put_raw") as mock_put:
        client.update_issuetype("TEST-456", "Story")
        mock_put.assert_called_once_with(
            "/rest/api/3/issue/TEST-456",
            {"fields": {"issuetype": {"name": "Story"}}},
        )


# ---------------------------------------------------------------------------
# 3. update_comment calls ACLI with correct flags
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_update_comment_calls_acli_with_correct_flags(acli: ModuleType) -> None:
    """AcliClient.update_comment runs ACLI comment update with --key, --id, --body."""
    client = _make_client(acli)
    mock_result = MagicMock(stdout='{"id": "10001", "body": "updated"}', stderr="")
    with patch.object(client, "_run", return_value=mock_result) as mock_run:
        result = client.update_comment("TEST-789", "10001", "updated body")
        mock_run.assert_called_once_with(
            [
                "jira",
                "workitem",
                "comment",
                "update",
                "--key",
                "TEST-789",
                "--id",
                "10001",
                "--body",
                "updated body",
                "--json",
            ]
        )
        assert result == {"id": "10001", "body": "updated"}


@pytest.mark.unit
@pytest.mark.scripts
def test_update_comment_handles_empty_stdout(acli: ModuleType) -> None:
    """update_comment returns empty dict when ACLI produces no output."""
    client = _make_client(acli)
    mock_result = MagicMock(stdout="", stderr="")
    with patch.object(client, "_run", return_value=mock_result):
        result = client.update_comment("TEST-789", "10001", "body")
        assert result == {}


# ---------------------------------------------------------------------------
# 4. delete_comment calls REST DELETE
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_delete_comment_calls_rest_delete(acli: ModuleType) -> None:
    """AcliClient.delete_comment sends DELETE to /rest/api/3/issue/{key}/comment/{id}."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_delete") as mock_delete:
        client.delete_comment("TEST-123", "10042")
        mock_delete.assert_called_once_with("/rest/api/3/issue/TEST-123/comment/10042")


# ---------------------------------------------------------------------------
# 5. get_issue uses search (not view)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_uses_search_not_view(acli: ModuleType) -> None:
    """Module-level get_issue must use 'search --jql' instead of 'view'."""
    issue_data = [{"key": "TEST-1", "summary": "Test issue", "status": "To Do"}]
    mock_result = MagicMock(stdout=json.dumps(issue_data), stderr="")

    with patch.object(acli, "_run_acli", return_value=mock_result) as mock_run:
        result = acli.get_issue("TEST-1")

    # Verify the command uses 'search' not 'view'
    called_cmd = mock_run.call_args[0][0]
    assert "search" in called_cmd, f"Expected 'search' in cmd, got: {called_cmd}"
    assert "view" not in called_cmd, f"'view' should not be in cmd: {called_cmd}"
    assert "--jql" in called_cmd
    assert "key = TEST-1" in called_cmd
    assert result == issue_data[0]


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_raises_on_empty_result(acli: ModuleType) -> None:
    """get_issue raises RuntimeError when search returns no results."""
    mock_result = MagicMock(stdout="[]", stderr="")

    with patch.object(acli, "_run_acli", return_value=mock_result):
        with pytest.raises(RuntimeError, match="not found"):
            acli.get_issue("NONEXIST-999")


@pytest.mark.unit
@pytest.mark.scripts
def test_get_issue_handles_dict_response(acli: ModuleType) -> None:
    """get_issue handles ACLI responses wrapped in {"issues": [...]}."""
    issue_data = {"issues": [{"key": "TEST-2", "summary": "Wrapped"}]}
    mock_result = MagicMock(stdout=json.dumps(issue_data), stderr="")

    with patch.object(acli, "_run_acli", return_value=mock_result):
        result = acli.get_issue("TEST-2")
        assert result["key"] == "TEST-2"


# ---------------------------------------------------------------------------
# 6. _call_with_backoff retries on 429
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_call_with_backoff_retries_on_429(acli: ModuleType) -> None:
    """_call_with_backoff retries on HTTP 429 and succeeds on retry."""
    call_count = 0

    def flaky_fn():
        nonlocal call_count
        call_count += 1
        if call_count < 3:
            # Simulate 429 response
            resp = BytesIO(b"Rate limited")
            err = urllib.error.HTTPError(
                "https://test.atlassian.net/rest/api/3/issue/TEST-1",
                429,
                "Too Many Requests",
                {},
                resp,
            )
            raise err
        return "success"

    with patch("time.sleep"):  # Don't actually sleep in tests
        result = acli._call_with_backoff(flaky_fn, max_retries=5)

    assert result == "success"
    assert call_count == 3  # 2 failures + 1 success


@pytest.mark.unit
@pytest.mark.scripts
def test_call_with_backoff_raises_after_max_retries(acli: ModuleType) -> None:
    """_call_with_backoff raises RetryExhaustedError after all retries."""

    def always_429():
        resp = BytesIO(b"Rate limited")
        raise urllib.error.HTTPError(
            "https://test.atlassian.net/rest/api/3/issue/TEST-1",
            429,
            "Too Many Requests",
            {},
            resp,
        )

    with patch("time.sleep"):
        with pytest.raises(acli.RetryExhaustedError):
            acli._call_with_backoff(always_429, max_retries=3)


@pytest.mark.unit
@pytest.mark.scripts
def test_call_with_backoff_respects_retry_after_header(acli: ModuleType) -> None:
    """_call_with_backoff reads Retry-After header for delay."""
    call_count = 0

    def retry_after_fn():
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            resp = BytesIO(b"Rate limited")
            headers = {"Retry-After": "7"}
            err = urllib.error.HTTPError(
                "https://test.atlassian.net/rest/api/3/issue/TEST-1",
                429,
                "Too Many Requests",
                headers,
                resp,
            )
            raise err
        return "ok"

    with patch("time.sleep") as mock_sleep, patch("random.random", return_value=0.5):
        result = acli._call_with_backoff(retry_after_fn, max_retries=3)

    assert result == "ok"
    # Verify the delay used Retry-After (7) + jitter (0.5) = 7.5
    assert mock_sleep.call_count == 1
    delay_used = mock_sleep.call_args[0][0]
    assert 7.0 <= delay_used <= 8.0, f"Expected ~7.5s delay, got {delay_used}"


@pytest.mark.unit
@pytest.mark.scripts
def test_call_with_backoff_passes_through_non_429(acli: ModuleType) -> None:
    """_call_with_backoff does not retry non-429 HTTP errors."""

    def server_error():
        resp = BytesIO(b"Internal Server Error")
        raise urllib.error.HTTPError(
            "https://test.atlassian.net/rest/api/3/issue/TEST-1",
            500,
            "Internal Server Error",
            {},
            resp,
        )

    with pytest.raises(urllib.error.HTTPError) as exc_info:
        acli._call_with_backoff(server_error, max_retries=3)
    assert exc_info.value.code == 500


# ---------------------------------------------------------------------------
# 7. _direct_rest_delete sends correct request
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_direct_rest_delete_sends_delete_request(acli: ModuleType) -> None:
    """AcliClient._direct_rest_delete sends a DELETE with correct auth headers."""
    client = _make_client(acli)
    mock_resp = MagicMock()
    mock_resp.read.return_value = b""
    mock_resp.__enter__ = MagicMock(return_value=mock_resp)
    mock_resp.__exit__ = MagicMock(return_value=False)

    with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen:
        client._direct_rest_delete("/rest/api/3/issue/TEST-1/comment/10042")

    req = mock_urlopen.call_args[0][0]
    assert req.get_method() == "DELETE"
    assert "test.atlassian.net" in req.full_url
    assert "/comment/10042" in req.full_url
    assert "Authorization" in req.headers
    assert req.headers.get("Accept") == "application/json"


# ---------------------------------------------------------------------------
# 8. _direct_rest_put_raw includes Accept header
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_direct_rest_put_raw_includes_accept_header(acli: ModuleType) -> None:
    """_direct_rest_put_raw sends Accept: application/json header."""
    client = _make_client(acli)
    mock_resp = MagicMock()
    mock_resp.read.return_value = b""
    mock_resp.__enter__ = MagicMock(return_value=mock_resp)
    mock_resp.__exit__ = MagicMock(return_value=False)

    with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen:
        client._direct_rest_put_raw("/rest/api/3/issue/TEST-1", {"fields": {}})

    req = mock_urlopen.call_args[0][0]
    assert req.headers.get("Accept") == "application/json"


# ---------------------------------------------------------------------------
# 9. update_issue routes priority to update_priority (module-level)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_update_issue_routes_priority_to_rest(acli: ModuleType) -> None:
    """Module-level update_issue calls update_priority instead of skipping."""
    with patch.object(acli, "update_priority") as mock_priority:
        # No other fields — just priority update
        result = acli.update_issue("TEST-100", priority=1)

    mock_priority.assert_called_once_with("TEST-100", "High", acli_cmd=None)
    assert result["key"] == "TEST-100"


# ---------------------------------------------------------------------------
# 10. _rest_urlopen_with_retry — transient TimeoutError retries then succeeds
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_rest_urlopen_retry_on_timeout_succeeds(acli: ModuleType) -> None:
    """_rest_urlopen_with_retry retries twice on TimeoutError then returns response.

    Scenario: urlopen raises TimeoutError twice then returns a successful
    response on the third call.  Asserts:
    - urlopen is called exactly 3 times.
    - The final return value is the successful response.
    """
    import urllib.request as _ureq

    client = _make_client(acli)

    success_resp = MagicMock()
    success_resp.__enter__ = lambda s: s
    success_resp.__exit__ = MagicMock(return_value=False)
    success_resp.read = MagicMock(return_value=b'{"ok": true}')

    call_count = 0

    def fake_urlopen(req, timeout=None):
        nonlocal call_count
        call_count += 1
        if call_count < 3:
            raise TimeoutError("The read operation timed out")
        return success_resp

    req = _ureq.Request("https://example.atlassian.net/rest/api/3/test")

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        with patch("time.sleep"):  # skip actual sleep in tests
            result = client._rest_urlopen_with_retry(req, timeout=10)

    assert call_count == 3, (
        f"Expected 3 urlopen calls (2 TimeoutErrors + 1 success); got {call_count}"
    )
    assert result is success_resp, "Must return the successful response object"


# ---------------------------------------------------------------------------
# 11. _rest_urlopen_with_retry — 4xx HTTPError is NOT retried
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_rest_urlopen_no_retry_on_http_error(acli: ModuleType) -> None:
    """_rest_urlopen_with_retry does NOT retry on HTTP 4xx errors.

    Scenario: urlopen raises HTTPError(404) on the first call.  Asserts:
    - urlopen is called exactly once (no retries).
    - HTTPError is re-raised immediately.
    """
    import urllib.error as _uerr
    import urllib.request as _ureq

    client = _make_client(acli)

    call_count = 0

    def fake_urlopen(req, timeout=None):
        nonlocal call_count
        call_count += 1
        raise _uerr.HTTPError(
            url="https://example.atlassian.net/rest/api/3/missing",
            code=404,
            msg="Not Found",
            hdrs=None,  # type: ignore[arg-type]
            fp=None,
        )

    req = _ureq.Request("https://example.atlassian.net/rest/api/3/missing")

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        with patch("time.sleep"):
            with pytest.raises(_uerr.HTTPError) as exc_info:
                client._rest_urlopen_with_retry(req, timeout=10)

    assert call_count == 1, (
        f"HTTPError (4xx) must not be retried; urlopen called {call_count} time(s)"
    )
    assert exc_info.value.code == 404
