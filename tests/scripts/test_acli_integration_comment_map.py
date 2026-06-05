"""AcliClient.get_comment_map tests (comment-state enrichment, bug 8b25 follow-on).

get_comment_map issues ONE paged POST /rest/api/3/search/jql with
fields=["comment"], returning {jira_key → comment-field dict} for entries the
search returned a comment field for. Keys without a comment field are omitted
so the caller falls back to per-ticket get_comments (never-emit-blind invariant).
Pagination + 410/transient degradation mirror get_parent_map.

Test: python3 -m pytest tests/scripts/test_acli_integration_comment_map.py
"""

from __future__ import annotations

import importlib.util
import logging
import urllib.error
from io import BytesIO
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

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
    if not SCRIPT_PATH.exists():
        pytest.fail(f"acli-integration.py not found at {SCRIPT_PATH}")
    return _load_module()


def _make_client(acli_mod: ModuleType) -> object:
    return acli_mod.AcliClient(
        jira_url="https://test.atlassian.net",
        user="test@example.com",
        api_token="fake-token",
        jira_project="TEST",
    )


def _http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        url="https://test.atlassian.net/rest/api/3/search/jql",
        code=code,
        msg="error",
        hdrs=None,  # type: ignore[arg-type]
        fp=BytesIO(b""),
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_get_comment_map_jql_endpoint_paginates_and_omits_absent(
    acli: ModuleType,
) -> None:
    """Two-page cursor walk on /search/jql; entries without a comment field omitted."""
    client = _make_client(acli)
    page1 = {
        "issues": [
            {"key": "DIG-1", "fields": {"comment": {"comments": [{"body": "a"}]}}},
            {"key": "DIG-2", "fields": {}},  # no comment field → omitted
        ],
        "isLast": False,
        "nextPageToken": "TOK",
    }
    page2 = {
        "issues": [
            {"key": "DIG-3", "fields": {"comment": {"comments": []}}},
        ],
        "isLast": True,
        "nextPageToken": None,
    }
    with patch.object(
        client, "_direct_rest_post_json", side_effect=[page1, page2]
    ) as mock_post:
        result = client.get_comment_map("DIG")

    assert result == {
        "DIG-1": {"comments": [{"body": "a"}]},
        "DIG-3": {"comments": []},
    }
    assert "DIG-2" not in result, "entries lacking a comment field must be omitted"
    assert mock_post.call_count == 2
    for call in mock_post.call_args_list:
        assert call.args[0] == "/rest/api/3/search/jql"
    first_body = mock_post.call_args_list[0].args[1]
    assert first_body["fields"] == ["comment"]
    assert "startAt" not in first_body
    assert mock_post.call_args_list[1].args[1]["nextPageToken"] == "TOK"


@pytest.mark.unit
@pytest.mark.scripts
def test_get_comment_map_410_logs_error(
    acli: ModuleType, caplog: pytest.LogCaptureFixture
) -> None:
    """HTTP 410 → ERROR (endpoint retirement is loud), empty map."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_post_json", side_effect=_http_error(410)):
        with caplog.at_level(logging.ERROR):
            result = client.get_comment_map("DIG")
    assert result == {}
    assert [r for r in caplog.records if r.levelno == logging.ERROR]


@pytest.mark.unit
@pytest.mark.scripts
def test_get_comment_map_transient_warns(
    acli: ModuleType, caplog: pytest.LogCaptureFixture
) -> None:
    """A non-410 fault stays at WARNING and returns an empty map (fallback)."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_post_json", side_effect=_http_error(503)):
        with caplog.at_level(logging.WARNING):
            result = client.get_comment_map("DIG")
    assert result == {}
    assert not [r for r in caplog.records if r.levelno == logging.ERROR]
    assert [r for r in caplog.records if r.levelno == logging.WARNING]
