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

    mock_client.update_issue.assert_called_once_with("DSO-42", fields)
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
