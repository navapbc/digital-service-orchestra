"""Tests for AcliClient.get_issue_property and _direct_rest_get in acli-integration.py.

Contract:
  - AcliClient.get_issue_property(jira_key, property_key) sends a GET request to
    /rest/api/3/issue/{jira_key}/properties/{property_key} with
    Authorization: Basic base64(user:api_token) and returns the parsed 'value' field.
  - AcliClient._direct_rest_get(path) is the underlying helper; it issues a GET
    with Authorization Basic header and 10s timeout, parses response as JSON, and
    returns the resulting dict.

Test: python3 -m pytest tests/scripts/test_acli_integration_get_issue_property.py
"""

from __future__ import annotations

import base64
import importlib.util
import json
import urllib.request
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
def test_get_issue_property_returns_value(acli: ModuleType) -> None:
    """get_issue_property calls _direct_rest_get on the correct path and returns response['value']."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    property_value = "abc-123"
    response_payload = {"value": property_value, "key": "dso_local_id"}

    mock_response = MagicMock()
    mock_response.__enter__ = lambda s: s
    mock_response.__exit__ = MagicMock(return_value=False)
    mock_response.read.return_value = json.dumps(response_payload).encode("utf-8")

    with patch("urllib.request.urlopen", return_value=mock_response) as mock_urlopen:
        result = client.get_issue_property("PROJ-1", "dso_local_id")

    assert mock_urlopen.called, "urlopen was never called"
    call_args = mock_urlopen.call_args
    request_obj = call_args[0][0]
    assert isinstance(request_obj, urllib.request.Request)
    assert "/rest/api/3/issue/PROJ-1/properties/dso_local_id" in request_obj.full_url
    assert result == property_value, (
        f"Expected get_issue_property to return '{property_value}', got '{result}'"
    )


@pytest.mark.scripts
def test_direct_rest_get_uses_basic_auth_and_timeout(acli: ModuleType) -> None:
    """_direct_rest_get issues a GET with Authorization Basic header and timeout=10."""
    client = acli.AcliClient(
        jira_url="https://jira.example.com",
        user="u",
        api_token="t",
    )
    expected_creds = base64.b64encode(b"u:t").decode()
    expected_header = f"Basic {expected_creds}"
    response_payload = {"value": "some-value"}

    mock_response = MagicMock()
    mock_response.__enter__ = lambda s: s
    mock_response.__exit__ = MagicMock(return_value=False)
    mock_response.read.return_value = json.dumps(response_payload).encode("utf-8")

    with patch("urllib.request.urlopen", return_value=mock_response) as mock_urlopen:
        result = client._direct_rest_get(
            "/rest/api/3/issue/PROJ-1/properties/dso_local_id"
        )

    assert mock_urlopen.called, "urlopen was never called"
    call_args = mock_urlopen.call_args
    # timeout is passed as second positional arg or keyword arg
    if len(call_args[0]) > 1:
        timeout_val = call_args[0][1]
    else:
        timeout_val = call_args[1].get("timeout")
    assert timeout_val == 10, f"Expected timeout=10, got {timeout_val}"

    request_obj = call_args[0][0]
    assert isinstance(request_obj, urllib.request.Request)
    assert request_obj.method == "GET", f"Expected GET method, got {request_obj.method}"
    auth_header = request_obj.get_header("Authorization")
    assert auth_header == expected_header, (
        f"Expected Authorization header '{expected_header}', got '{auth_header}'"
    )
    assert result == response_payload, (
        f"Expected _direct_rest_get to return {response_payload}, got {result}"
    )
