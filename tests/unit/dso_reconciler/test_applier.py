"""Tests for dso_reconciler/applier.py.

Covers:
- Manifest written to the correct path
- Manifest has correct shape (pass_id, mutation_count, mutations)
- Empty mutations list produces manifest with mutation_count=0
- "create" action routes to client.create_issue
- "update" action routes to client.update_issue
- "delete" action routes to client.transition_issue("Closed")
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

import pytest


def _init_git_repo(path: Path) -> None:
    """Initialize tmp_path as a minimal git repo so applier.apply()'s
    concurrency.snapshot_head() (git rev-parse HEAD) succeeds.

    apply() reads HEAD via git for the rebase-retry concurrency check; in
    tests we just need any committed HEAD, not a meaningful one.
    """
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "test"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "commit.gpgsign", "false"], check=True)
    (path / ".dummy").write_text("seed")
    subprocess.run(["git", "-C", str(path), "add", ".dummy"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-q", "-m", "seed"], check=True)

# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
)


def _load_applier():
    spec = importlib.util.spec_from_file_location("applier", APPLIER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["applier"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def applier():
    """Load the applier module, failing all tests if absent."""
    if not APPLIER_PATH.exists():
        pytest.fail(
            f"applier.py not found at {APPLIER_PATH} — "
            "implement the module to make tests pass."
        )
    return _load_applier()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_mock_acli_module() -> tuple[types.ModuleType, MagicMock]:
    """Return (mock acli module, mock client instance) with tracked method calls."""
    mock_client = MagicMock()
    mock_client.search_issues = MagicMock(return_value=[])
    mock_client.create_issue = MagicMock(return_value={"key": "DSO-1"})
    mock_client.update_issue = MagicMock(return_value={"key": "DSO-2"})
    mock_client.transition_issue = MagicMock(return_value=None)
    mock_client.add_label = MagicMock(return_value=None)
    mock_client.set_entity_property = MagicMock(return_value=None)

    mock_acli_mod = types.ModuleType("acli_integration")
    mock_acli_mod.AcliClient = MagicMock(return_value=mock_client)

    return mock_acli_mod, mock_client


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_manifest_written_to_correct_path(tmp_path, applier):
    """apply() writes manifest to bridge_state/snapshots/<pass_id>.manifest.json."""
    pass_id = "2026-05-22-pass-01"
    mock_acli_mod, _ = _make_mock_acli_module()
    _init_git_repo(tmp_path)

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        manifest_path = applier.apply([], pass_id, repo_root=tmp_path)

    expected_path = tmp_path / "bridge_state" / "snapshots" / f"{pass_id}.manifest.json"
    assert manifest_path == expected_path, (
        f"Expected manifest at {expected_path}, got {manifest_path}"
    )
    assert expected_path.exists(), "Manifest file was not created on disk"


def test_manifest_has_correct_shape(tmp_path, applier):
    """Manifest JSON contains pass_id, mutation_count, and mutations fields."""
    pass_id = "2026-05-22-pass-02"
    mutations = [{"action": "create", "fields": {"summary": "Test issue"}}]
    mock_acli_mod, _ = _make_mock_acli_module()
    _init_git_repo(tmp_path)

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        manifest_path = applier.apply(mutations, pass_id, repo_root=tmp_path)

    data = json.loads(manifest_path.read_text())
    assert "pass_id" in data, "Manifest missing 'pass_id' field"
    assert "mutation_count" in data, "Manifest missing 'mutation_count' field"
    assert "mutations" in data, "Manifest missing 'mutations' field"
    assert data["pass_id"] == pass_id
    assert data["mutation_count"] == 1
    assert isinstance(data["mutations"], list)


def test_empty_mutations_produces_manifest_with_zero_count(tmp_path, applier):
    """Empty mutations list produces a manifest with mutation_count=0 and empty mutations."""
    pass_id = "2026-05-22-pass-03"
    mock_acli_mod, _ = _make_mock_acli_module()
    _init_git_repo(tmp_path)

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        manifest_path = applier.apply([], pass_id, repo_root=tmp_path)

    assert manifest_path.exists(), "Manifest must be written even for empty mutations"
    data = json.loads(manifest_path.read_text())
    assert data["mutation_count"] == 0, (
        f"Expected mutation_count=0, got {data['mutation_count']}"
    )
    assert data["mutations"] == [], (
        f"Expected empty mutations list, got {data['mutations']}"
    )


def test_create_action_routes_to_create_issue(tmp_path, applier):
    """'create' action calls client.create_issue with mutation fields."""
    pass_id = "2026-05-22-pass-04"
    fields = {"summary": "New feature", "issuetype": {"name": "Story"}}
    mutations = [{"action": "create", "fields": fields}]
    mock_acli_mod, mock_client = _make_mock_acli_module()
    _init_git_repo(tmp_path)

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        applier.apply(mutations, pass_id, repo_root=tmp_path)

    mock_client.create_issue.assert_called_once_with(fields)
    mock_client.update_issue.assert_not_called()
    mock_client.transition_issue.assert_not_called()


def test_update_action_routes_to_update_issue(tmp_path, applier):
    """'update' action calls client.update_issue with mutation key and fields."""
    pass_id = "2026-05-22-pass-05"
    fields = {"summary": "Updated summary"}
    mutations = [{"action": "update", "key": "DSO-42", "fields": fields}]
    mock_acli_mod, mock_client = _make_mock_acli_module()
    _init_git_repo(tmp_path)

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        applier.apply(mutations, pass_id, repo_root=tmp_path)

    # F3: fields must be unpacked as kwargs (real signature: update_issue(key, **kwargs))
    mock_client.update_issue.assert_called_once_with("DSO-42", **fields)
    mock_client.create_issue.assert_not_called()
    mock_client.transition_issue.assert_not_called()


def test_delete_action_routes_to_transition_issue_closed(tmp_path, applier):
    """'delete' action calls client.transition_issue(key, 'Closed')."""
    pass_id = "2026-05-22-pass-06"
    mutations = [{"action": "delete", "key": "DSO-99"}]
    mock_acli_mod, mock_client = _make_mock_acli_module()
    _init_git_repo(tmp_path)

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        applier.apply(mutations, pass_id, repo_root=tmp_path)

    mock_client.transition_issue.assert_called_once_with("DSO-99", "Closed")
    mock_client.create_issue.assert_not_called()
    mock_client.update_issue.assert_not_called()


def test_delete_one_treats_404_as_success(applier):
    """F5 regression: delete_one must swallow JiraAPIError(404) on transition.

    Because the differ emits a delete precisely when the issue has already
    disappeared from Jira, the subsequent transition_issue call may target a
    gone-from-Jira key. A 404 there means the desired post-state is already
    satisfied — delete_one returns silently. Other 4xx propagate.
    """
    from unittest.mock import MagicMock

    client = MagicMock()
    client.transition_issue.side_effect = applier.JiraAPIError(
        "Issue does not exist", status_code=404
    )

    mutation = {"action": "delete", "key": "DSO-GONE"}
    # Must NOT raise — 404 on delete is success.
    applier.delete_one(mutation, client)


def test_delete_one_propagates_non_404_jira_errors(applier):
    """F5: 4xx other than 404 must still propagate from delete_one."""
    from unittest.mock import MagicMock
    import pytest as _pytest

    client = MagicMock()
    client.transition_issue.side_effect = applier.JiraAPIError(
        "Forbidden", status_code=403
    )
    mutation = {"action": "delete", "key": "DSO-FORBIDDEN"}
    with _pytest.raises(applier.JiraAPIError):
        applier.delete_one(mutation, client)


def test_apply_constructs_client_with_env_derived_args(tmp_path, applier, monkeypatch):
    """Regression: apply() must call AcliClient(jira_url=..., user=..., api_token=...)
    using env vars JIRA_URL / JIRA_USER / JIRA_API_TOKEN — not AcliClient() with no args.

    The real AcliClient requires three credential arguments; before this fix
    apply() invoked it positionally with no args, which raises TypeError on
    every real reconciler pass and shows up as 'apply did not execute' in
    bridge_state without any other diagnostic. The unit-test suite did not
    catch this because mocks accepted any signature.
    """
    pass_id = "2026-05-23-env-args"
    _init_git_repo(tmp_path)

    monkeypatch.setenv("JIRA_URL", "https://example.atlassian.net")
    monkeypatch.setenv("JIRA_USER", "ci-bot@example.com")
    monkeypatch.setenv("JIRA_API_TOKEN", "tok-abc-123")

    mock_acli_mod, _ = _make_mock_acli_module()
    constructor = mock_acli_mod.AcliClient  # MagicMock

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        applier.apply([], pass_id, repo_root=tmp_path)

    # AcliClient must have been constructed exactly once with the env-derived kwargs.
    constructor.assert_called_once()
    call = constructor.call_args
    assert call.kwargs == {
        "jira_url": "https://example.atlassian.net",
        "user": "ci-bot@example.com",
        "api_token": "tok-abc-123",
    }, (
        f"AcliClient must be constructed with env-derived kwargs; got args="
        f"{call.args!r}, kwargs={call.kwargs!r}"
    )
    # Constructor must not have been called positionally — the real signature
    # is keyword-style and a positional call risks ordering bugs.
    assert call.args == (), (
        f"AcliClient must not be constructed positionally; got args={call.args!r}"
    )


def test_apply_constructs_client_with_empty_strings_when_env_unset(
    tmp_path, applier, monkeypatch
):
    """When the JIRA_* env vars are absent, apply() must still construct
    AcliClient with empty-string defaults so test/CI shims that don't set the
    env still work (mirrors fetcher.fetch_snapshot's pattern)."""
    pass_id = "2026-05-23-env-unset"
    _init_git_repo(tmp_path)

    monkeypatch.delenv("JIRA_URL", raising=False)
    monkeypatch.delenv("JIRA_USER", raising=False)
    monkeypatch.delenv("JIRA_API_TOKEN", raising=False)

    mock_acli_mod, _ = _make_mock_acli_module()
    constructor = mock_acli_mod.AcliClient

    with __import__("unittest.mock", fromlist=["patch"]).patch.object(
        applier, "_load_acli", return_value=mock_acli_mod
    ):
        applier.apply([], pass_id, repo_root=tmp_path)

    constructor.assert_called_once()
    assert constructor.call_args.kwargs == {
        "jira_url": "",
        "user": "",
        "api_token": "",
    }


def test_update_one_unpacks_fields_as_kwargs(applier):
    """F3 regression: update_one must unpack fields into kwargs.

    AcliClient.update_issue's real signature is ``update_issue(jira_key, **kwargs)``.
    Before F3, applier.update_one called ``client.update_issue(key, fields_dict)``
    positionally, which raises TypeError against the real client. The fix
    unpacks the field dict into kwargs.
    """
    from unittest.mock import MagicMock

    client = MagicMock()
    client.update_issue.return_value = {"key": "DSO-555"}

    mutation = {
        "action": "update",
        "key": "DSO-555",
        "fields": {"summary": "new summary", "priority": "high"},
    }
    applier.update_one(mutation, client)

    client.update_issue.assert_called_once()
    call = client.update_issue.call_args
    # Only the jira_key may appear as a positional argument.
    assert call.args == ("DSO-555",), (
        f"update_one must pass only the jira_key positionally; got {call.args!r}"
    )
    # All field entries must appear as kwargs.
    assert call.kwargs == {"summary": "new summary", "priority": "high"}, (
        f"update_one must unpack fields as kwargs; got {call.kwargs!r}"
    )
