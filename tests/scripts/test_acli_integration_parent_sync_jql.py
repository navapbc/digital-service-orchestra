"""Parent-sync live-fix tests (bug 8b25): JQL endpoint migration, nextPageToken
pagination, HTTP 410 ERROR logging, and create-time parent attachment.

Contract (live-proven, ticket 8b25):
  - POST /rest/api/3/search is RETIRED (HTTP 410). get_parent_map now POSTs to
    /rest/api/3/search/jql with fields=["parent"], paginating via a
    nextPageToken cursor (no startAt, no total).
  - HTTP 410 from the search endpoint is logged at ERROR (API retirement),
    not WARNING (transient).
  - create_issue attaches the parent: the no-JSON path via --parent <key>;
    the --from-json (priority) path via a set_parent fallback after create.
  - A Jira hierarchy rejection (HTTP 400) on a parent op logs a WARNING and
    continues the pass (generic 400-skip).

Test: python3 -m pytest tests/scripts/test_acli_integration_parent_sync_jql.py
"""

from __future__ import annotations

import importlib.util
import logging
import urllib.error
from io import BytesIO
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


# ---------------------------------------------------------------------------
# 1. get_parent_map uses /rest/api/3/search/jql with nextPageToken pagination
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_parent_map_jql_endpoint_two_page_pagination(acli: ModuleType) -> None:
    """Two-page nextPageToken cursor walk hits /search/jql, never sends startAt."""
    client = _make_client(acli)

    page1 = {
        "issues": [
            {"key": "DIG-1", "fields": {"parent": {"key": "DIG-100"}}},
            {"key": "DIG-2", "fields": {}},
        ],
        "isLast": False,
        "nextPageToken": "TOKEN_A",
    }
    page2 = {
        "issues": [
            {"key": "DIG-3", "fields": {"parent": {"key": "DIG-100"}}},
        ],
        "isLast": True,
        "nextPageToken": None,
    }

    with patch.object(
        client, "_direct_rest_post_json", side_effect=[page1, page2]
    ) as mock_post:
        result = client.get_parent_map("DIG")

    assert result == {
        "DIG-1": "DIG-100",
        "DIG-2": None,
        "DIG-3": "DIG-100",
    }
    assert mock_post.call_count == 2
    # Both calls hit the new jql endpoint.
    for call in mock_post.call_args_list:
        assert call.args[0] == "/rest/api/3/search/jql"
    # First body: no nextPageToken, fields=["parent"], no startAt.
    first_body = mock_post.call_args_list[0].args[1]
    assert "nextPageToken" not in first_body
    assert "startAt" not in first_body
    assert first_body["fields"] == ["parent"]
    # Second body carries the cursor token from page1.
    second_body = mock_post.call_args_list[1].args[1]
    assert second_body["nextPageToken"] == "TOKEN_A"
    assert "startAt" not in second_body


@pytest.mark.unit
@pytest.mark.scripts
def test_get_parent_map_single_key_jql_resolves_parent(acli: ModuleType) -> None:
    """Calling convention contract (bug 8b25 continuation): the supported way to
    look up ONE issue's parent is ``get_parent_map(project, jql='key = DIG-N')``
    — ``project`` is a STRING project key and the per-key narrowing goes through
    ``jql``. This is the call shape the e2e field-validation probe must use.

    The prior probe regression passed a 1-element LIST of issue keys as the
    ``project`` positional (``get_parent_map(['DIG-N'])``), which produced the
    JQL ``project = ['DIG-N']`` → HTTP 400 → empty map → a false-negative
    "parent not set" verdict even though the reconciler had correctly attached
    the parent. This test pins the correct convention so that mistake cannot
    silently re-enter via the probe assertion path.
    """
    client = _make_client(acli)
    page = {
        "issues": [{"key": "DIG-5491", "fields": {"parent": {"key": "DIG-5490"}}}],
        "isLast": True,
        "nextPageToken": None,
    }
    with patch.object(
        client, "_direct_rest_post_json", side_effect=[page]
    ) as mock_post:
        result = client.get_parent_map("DIG", jql="key = DIG-5491")

    assert result.get("DIG-5491") == "DIG-5490"
    # The per-key narrowing is carried in the JQL body, not by misusing the
    # project positional. The endpoint receives the explicit key-scoped JQL.
    body = mock_post.call_args_list[0].args[1]
    assert body["jql"] == "key = DIG-5491"


@pytest.mark.unit
@pytest.mark.scripts
def test_get_parent_map_project_arg_is_string_not_list(acli: ModuleType) -> None:
    """Guard the probe bug class: when no ``jql`` override is given, the default
    JQL is ``project = <project>`` built from the STRING project positional.

    A list passed as ``project`` would stringify into ``project = ['DIG-N']`` —
    a malformed JQL Jira rejects with HTTP 400. This test documents that the
    default JQL embeds the bare project token, so callers must pass a project
    KEY string here and route per-issue filtering through ``jql=``.
    """
    client = _make_client(acli)
    page = {"issues": [], "isLast": True, "nextPageToken": None}
    with patch.object(
        client, "_direct_rest_post_json", side_effect=[page]
    ) as mock_post:
        client.get_parent_map("DIG")
    body = mock_post.call_args_list[0].args[1]
    assert body["jql"] == "project = DIG"
    # A list would have produced "project = ['DIG']" — explicitly NOT this.
    assert "[" not in body["jql"]


@pytest.mark.unit
@pytest.mark.scripts
def test_get_parent_map_stops_on_islast_without_token(acli: ModuleType) -> None:
    """A single isLast=True page (token present but isLast wins) stops the walk."""
    client = _make_client(acli)
    page = {
        "issues": [{"key": "DIG-9", "fields": {"parent": {"key": "DIG-5"}}}],
        "isLast": True,
        "nextPageToken": "IGNORED",
    }
    with patch.object(
        client, "_direct_rest_post_json", side_effect=[page]
    ) as mock_post:
        result = client.get_parent_map("DIG")
    assert result == {"DIG-9": "DIG-5"}
    assert mock_post.call_count == 1


# ---------------------------------------------------------------------------
# 2. HTTP 410 from the retired endpoint logs at ERROR (loud), not WARNING
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_get_parent_map_410_logs_error(
    acli: ModuleType, caplog: pytest.LogCaptureFixture
) -> None:
    """HTTP 410 (endpoint retirement) → ERROR log naming the endpoint, empty map."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_post_json", side_effect=_http_error(410)):
        with caplog.at_level(logging.ERROR):
            result = client.get_parent_map("DIG")
    assert result == {}
    error_records = [r for r in caplog.records if r.levelno == logging.ERROR]
    assert error_records, "HTTP 410 must log at ERROR (API retirement is loud)"
    joined = " ".join(r.getMessage() for r in error_records)
    assert "410" in joined
    assert "/rest/api/3/search/jql" in joined


@pytest.mark.unit
@pytest.mark.scripts
def test_get_parent_map_transient_5xx_logs_warning_not_error(
    acli: ModuleType, caplog: pytest.LogCaptureFixture
) -> None:
    """A non-410 HTTPError stays at WARNING (transient), not ERROR."""
    client = _make_client(acli)
    with patch.object(client, "_direct_rest_post_json", side_effect=_http_error(503)):
        with caplog.at_level(logging.WARNING):
            result = client.get_parent_map("DIG")
    assert result == {}
    assert not [r for r in caplog.records if r.levelno == logging.ERROR]
    assert [r for r in caplog.records if r.levelno == logging.WARNING]


# ---------------------------------------------------------------------------
# 3. create cmd carries --parent (no-JSON path)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_issue_no_json_cmd_carries_parent(acli: ModuleType) -> None:
    """create_issue with a parent passes --parent <key> in the ACLI command."""
    created = MagicMock(returncode=0, stdout='{"key": "DIG-200"}', stderr="")
    with (
        patch.object(acli, "_run_acli", return_value=created) as mock_run,
        patch.object(acli, "_verify_created_issue", return_value={"key": "DIG-200"}),
    ):
        acli.create_issue("DIG", "Task", "child summary", parent="DIG-100")
    cmd = mock_run.call_args_list[0].args[0]
    assert "--parent" in cmd, f"--parent missing from create cmd: {cmd}"
    assert cmd[cmd.index("--parent") + 1] == "DIG-100"


# ---------------------------------------------------------------------------
# 4. --from-json (priority) create path falls back to set_parent
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_create_from_json_path_falls_back_to_set_parent(acli: ModuleType) -> None:
    """The priority (--from-json) create path attaches parent via set_parent."""
    client = _make_client(acli)
    fake_set_parent = MagicMock()
    client.set_parent = fake_set_parent  # type: ignore[attr-defined]

    with (
        patch.object(acli, "_create_issue_from_json", return_value={"key": "DIG-300"}),
    ):
        acli.create_issue(
            "DIG",
            "Task",
            "child",
            priority=1,
            parent="DIG-100",
            client=client,
        )
    fake_set_parent.assert_called_once_with("DIG-300", "DIG-100")


# ---------------------------------------------------------------------------
# 5. Hierarchy guard: HTTP 400 on set_parent fallback → WARNING + continue
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_from_json_parent_400_warns_and_continues(
    acli: ModuleType, caplog: pytest.LogCaptureFixture
) -> None:
    """A Jira hierarchy rejection (400) on the set_parent fallback is non-fatal."""
    client = _make_client(acli)
    client.set_parent = MagicMock(  # type: ignore[attr-defined]
        side_effect=urllib.error.HTTPError(
            url="x",
            code=400,
            msg="bad",
            hdrs=None,
            fp=BytesIO(b""),  # type: ignore[arg-type]
        )
    )
    with patch.object(acli, "_create_issue_from_json", return_value={"key": "DIG-301"}):
        with caplog.at_level(logging.WARNING):
            # Must NOT raise — the create succeeds, parent is skipped.
            result = acli.create_issue(
                "DIG", "Task", "c", priority=2, parent="DIG-7", client=client
            )
    assert result == {"key": "DIG-301"}
    joined = " ".join(r.getMessage() for r in caplog.records)
    assert "parent sync skipped" in joined
    assert "DIG-301" in joined


# ---------------------------------------------------------------------------
# 6. AcliClient.create_issue extracts parent from ticket_data (both shapes)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
@pytest.mark.parametrize(
    "parent_value",
    ["DIG-100", {"key": "DIG-100"}],
    ids=["bare-string", "nested-dict"],
)
def test_client_create_issue_threads_parent(
    acli: ModuleType, parent_value: object
) -> None:
    """AcliClient.create_issue forwards the parent (bare or nested) to create_issue."""
    client = _make_client(acli)
    with patch.object(
        acli, "create_issue", return_value={"key": "DIG-400"}
    ) as mock_create:
        client.create_issue(
            {
                "ticket_type": "task",
                "title": "child task",
                "parent": parent_value,
            }
        )
    kwargs = mock_create.call_args.kwargs
    assert kwargs.get("parent") == "DIG-100"
