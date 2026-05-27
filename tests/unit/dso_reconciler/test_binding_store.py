"""Unit tests for BindingStore — local-id ↔ jira-key binding persistence.

Follows the importlib loader convention established across this test tree
(see conftest.py docstring for rationale).
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# importlib loader — convention per conftest.py
# ---------------------------------------------------------------------------
_SRC = (
    Path(__file__).resolve().parents[3]
    / "plugins"
    / "dso"
    / "scripts"
    / "dso_reconciler"
    / "binding_store.py"
)

_spec = importlib.util.spec_from_file_location("binding_store", _SRC)
assert _spec and _spec.loader
_mod = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _mod
_spec.loader.exec_module(_mod)

BindingStore = _mod.BindingStore
load_binding_store = _mod.load_binding_store


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def store(tmp_path: Path) -> BindingStore:
    """Fresh BindingStore backed by a temporary directory."""
    return BindingStore(tmp_path)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestBindingLifecycle:
    """bind_pending → bind_confirm full lifecycle."""

    def test_bind_pending_then_confirm(self, store: BindingStore) -> None:
        store.bind_pending("abc-1234")
        assert store.is_bound("abc-1234")
        assert store.is_pending("abc-1234")
        assert store.get_jira_key("abc-1234") is None

        store.bind_confirm("abc-1234", "DIG-42")
        assert store.is_bound("abc-1234")
        assert not store.is_pending("abc-1234")
        assert store.get_jira_key("abc-1234") == "DIG-42"


class TestQueries:
    def test_get_jira_key_returns_none_for_unbound(
        self, store: BindingStore
    ) -> None:
        assert store.get_jira_key("nonexistent") is None

    def test_reverse_lookup(self, store: BindingStore) -> None:
        store.bind_pending("local-1")
        store.bind_confirm("local-1", "DIG-99")
        assert store.get_local_id("DIG-99") == "local-1"

    def test_reverse_lookup_returns_none_for_unknown_key(
        self, store: BindingStore
    ) -> None:
        assert store.get_local_id("DIG-0") is None

    def test_pending_bindings_listed(self, store: BindingStore) -> None:
        store.bind_pending("a")
        store.bind_pending("b")
        store.bind_confirm("b", "DIG-1")
        assert store.pending_bindings() == ["a"]

    def test_confirmed_count(self, store: BindingStore) -> None:
        store.bind_pending("x")
        store.bind_confirm("x", "DIG-10")
        store.bind_pending("y")
        assert store.confirmed_count() == 1


class TestUnbind:
    def test_unbind_removes_both_directions(self, store: BindingStore) -> None:
        store.bind_pending("tid")
        store.bind_confirm("tid", "DIG-7")
        assert store.is_bound("tid")
        assert store.get_local_id("DIG-7") == "tid"

        store.unbind("tid")
        assert not store.is_bound("tid")
        assert store.get_jira_key("tid") is None
        assert store.get_local_id("DIG-7") is None

    def test_unbind_noop_for_unknown(self, store: BindingStore) -> None:
        store.unbind("ghost")  # should not raise


class TestPersistence:
    def test_save_and_reload(self, tmp_path: Path) -> None:
        store1 = BindingStore(tmp_path)
        store1.bind_pending("id-a")
        store1.bind_confirm("id-a", "DIG-50")
        store1.save()

        store2 = BindingStore(tmp_path)
        assert store2.get_jira_key("id-a") == "DIG-50"
        assert store2.get_local_id("DIG-50") == "id-a"
        assert not store2.is_pending("id-a")

    def test_atomic_save(self, tmp_path: Path) -> None:
        """Verify the save path uses tempfile + os.replace (not direct write).

        We confirm atomicity by checking that if the store directory
        already exists, save() produces a file (not a partial write),
        and no temp files are left behind.
        """
        store = BindingStore(tmp_path)
        store.bind_pending("t1")
        store.save()

        bridge_dir = tmp_path / ".bridge_state"
        # After save, only bindings.json should exist (no leftover .tmp)
        files = list(bridge_dir.iterdir())
        assert len(files) == 1
        assert files[0].name == "bindings.json"

        # Verify content is valid JSON
        with open(files[0]) as f:
            data = json.load(f)
        assert data["version"] == 1
        assert "t1" in data["bindings"]


class TestRecovery:
    def test_recover_pending_found_in_jira(
        self, store: BindingStore
    ) -> None:
        store.bind_pending("lost-1")

        client = MagicMock()
        client.search_issues.return_value = [{"key": "DIG-200"}]

        count = store.recover_pending_bindings(client)

        assert count == 1
        assert store.get_jira_key("lost-1") == "DIG-200"
        assert not store.is_pending("lost-1")
        client.search_issues.assert_called_once_with('labels = "dso-id-lost-1"')

    def test_recover_pending_not_found_in_jira(
        self, store: BindingStore
    ) -> None:
        store.bind_pending("orphan-1")

        client = MagicMock()
        client.search_issues.return_value = []

        count = store.recover_pending_bindings(client)

        assert count == 1
        assert not store.is_bound("orphan-1")

    def test_recover_with_no_pending_is_noop(
        self, store: BindingStore
    ) -> None:
        client = MagicMock()
        assert store.recover_pending_bindings(client) == 0
        client.search_issues.assert_not_called()


class TestLoadBindingStore:
    def test_load_binding_store_creates_instance(
        self, tmp_path: Path
    ) -> None:
        tracker = tmp_path / ".tickets-tracker"
        tracker.mkdir()
        repo_root = tmp_path
        bs = load_binding_store(repo_root)
        assert isinstance(bs, BindingStore)
        assert not bs.is_bound("anything")
