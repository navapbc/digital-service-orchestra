"""RED tests for AcliClient.set_issue_property and _direct_rest_put in acli-integration.py.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL with AttributeError before set_issue_property and
_direct_rest_put are implemented in AcliClient.

Contract:
  - AcliClient.set_issue_property(jira_key, property_key, value) sends a PUT
    request to /rest/api/3/issue/{jira_key}/properties/{property_key} with
    Authorization: Basic base64(user:api_token) and a JSON body {"value": value}.
  - AcliClient._direct_rest_put(url, payload) is the underlying helper; it
    propagates urllib.error.HTTPError on 4xx/5xx responses (no silent swallowing).

Test: python3 -m pytest tests/scripts/test_acli_integration_set_issue_property.py
All tests must return non-zero (AttributeError) until the methods are implemented.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import urllib.error
import urllib.request
from io import BytesIO
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
ACLI_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "acli-integration.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("acli_integration", ACLI_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def acli() -> ModuleType:
    """Return the acli-integration module, failing all tests if absent (RED)."""
    if not ACLI_PATH.exists():
        pytest.fail(
            f"acli-integration.py not found at {ACLI_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.scripts
def test_set_issue_property_calls_put_on_correct_path(acli: ModuleType) -> None:
    """set_issue_property calls urlopen with a Request targeting the correct REST path."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    value = [{"path": "src/foo.py"}]
    mock_response = MagicMock()
    mock_response.__enter__ = lambda s: s
    mock_response.__exit__ = MagicMock(return_value=False)
    mock_response.read.return_value = b"{}"

    with patch("urllib.request.urlopen", return_value=mock_response) as mock_urlopen:
        client.set_issue_property("DSO-1", "dso.file_impact", value)

    assert mock_urlopen.called, "urlopen was never called"
    call_args = mock_urlopen.call_args
    request_obj = call_args[0][0]
    assert isinstance(request_obj, urllib.request.Request)
    assert "/rest/api/3/issue/DSO-1/properties/dso.file_impact" in request_obj.full_url


@pytest.mark.scripts
def test_set_issue_property_injects_authorization_header(acli: ModuleType) -> None:
    """set_issue_property injects a correct Basic Authorization header."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    expected_creds = base64.b64encode(b"u:t").decode()
    expected_header = f"Basic {expected_creds}"

    mock_response = MagicMock()
    mock_response.__enter__ = lambda s: s
    mock_response.__exit__ = MagicMock(return_value=False)
    mock_response.read.return_value = b"{}"

    with patch("urllib.request.urlopen", return_value=mock_response) as mock_urlopen:
        client.set_issue_property("DSO-1", "dso.file_impact", [{"path": "src/foo.py"}])

    request_obj = mock_urlopen.call_args[0][0]
    assert isinstance(request_obj, urllib.request.Request)
    auth_header = request_obj.get_header("Authorization")
    assert auth_header == expected_header, (
        f"Expected Authorization header '{expected_header}', got '{auth_header}'"
    )


@pytest.mark.scripts
def test_set_issue_property_sends_correct_json_body(acli: ModuleType) -> None:
    """set_issue_property sends a JSON body with key 'value' containing the passed value."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    value = [{"path": "src/foo.py"}]

    mock_response = MagicMock()
    mock_response.__enter__ = lambda s: s
    mock_response.__exit__ = MagicMock(return_value=False)
    mock_response.read.return_value = b"{}"

    with patch("urllib.request.urlopen", return_value=mock_response) as mock_urlopen:
        client.set_issue_property("DSO-1", "dso.file_impact", value)

    request_obj = mock_urlopen.call_args[0][0]
    assert isinstance(request_obj, urllib.request.Request)
    body = request_obj.data
    assert body is not None, "Request body (data) is None — expected JSON bytes"
    parsed = json.loads(body.decode("utf-8") if isinstance(body, bytes) else body)
    assert "value" in parsed, (
        f"Expected key 'value' in request body, got keys: {list(parsed.keys())}"
    )
    assert parsed["value"] == value


@pytest.mark.scripts
def test_set_issue_property_raises_on_http_error(acli: ModuleType) -> None:
    """set_issue_property propagates urllib.error.HTTPError on 4xx responses."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    http_error = urllib.error.HTTPError(
        url="https://jira.example.com/rest/api/3/issue/DSO-1/properties/dso.file_impact",
        code=400,
        msg="Bad Request",
        hdrs=None,  # type: ignore[arg-type]
        fp=BytesIO(b'{"errorMessages":["invalid property"]}'),
    )

    with patch("urllib.request.urlopen", side_effect=http_error):
        with pytest.raises(urllib.error.HTTPError):
            client.set_issue_property(
                "DSO-1", "dso.file_impact", [{"path": "src/foo.py"}]
            )
