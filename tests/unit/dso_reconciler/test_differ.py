"""Unit tests for dso_reconciler/differ.py — compute_mutations() pure function.

Tests cover:
  - test_identical_snapshots_produce_empty_list: same prev and next → no mutations.
  - test_excluded_fields_only_change_produces_no_mutations: only excluded fields differ → empty.
  - test_new_key_produces_create_mutation: key present in next but not prev → create.
  - test_removed_key_produces_delete_mutation: key present in prev but not next → delete.
  - test_changed_field_produces_update_mutation: existing key with changed field → update.
  - test_update_contains_only_changed_fields: unchanged fields are not in update payload.
  - test_excluded_field_not_in_update_payload: excluded field change is omitted from update.
  - test_pure_function_invariant: calling twice with same args returns identical result.
  - test_create_excludes_excluded_fields: create mutation payload omits excluded fields.
"""

from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading helpers
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
DIFFER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "differ.py"
)


def _load_differ() -> ModuleType:
    spec = importlib.util.spec_from_file_location("differ", DIFFER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def differ() -> ModuleType:
    return _load_differ()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _snapshot(**issues):
    """Build a snapshot dict from keyword arguments.

    Each value should itself be a dict of field_name → field_value.
    """
    return dict(issues)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_identical_snapshots_produce_empty_list(differ: ModuleType) -> None:
    snapshot = {"DSO-1": {"summary": "hello", "status": "open"}}
    result = differ.compute_mutations(snapshot, copy.deepcopy(snapshot))
    assert result == []


def test_empty_snapshots_produce_empty_list(differ: ModuleType) -> None:
    result = differ.compute_mutations({}, {})
    assert result == []


def test_excluded_fields_only_change_produces_no_mutations(differ: ModuleType) -> None:
    # Both excluded fields change — no mutation should be emitted.
    prev = {"DSO-1": {"dso_local_id": "old-local", "dso-id": "old-id"}}
    next_ = {"DSO-1": {"dso_local_id": "new-local", "dso-id": "new-id"}}
    result = differ.compute_mutations(prev, next_)
    assert result == []


def test_new_key_produces_create_mutation(differ: ModuleType) -> None:
    prev: dict = {}
    next_ = {"DSO-42": {"summary": "new issue", "priority": "high"}}
    result = differ.compute_mutations(prev, next_)
    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "create"
    assert mutation["key"] == "DSO-42"
    assert mutation["fields"] == {"summary": "new issue", "priority": "high"}


def test_removed_key_produces_delete_mutation(differ: ModuleType) -> None:
    prev = {"DSO-7": {"summary": "going away"}}
    next_: dict = {}
    result = differ.compute_mutations(prev, next_)
    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "delete"
    assert mutation["key"] == "DSO-7"
    assert mutation["fields"] == {}


def test_changed_field_produces_update_mutation(differ: ModuleType) -> None:
    prev = {"DSO-3": {"summary": "old summary", "status": "open"}}
    next_ = {"DSO-3": {"summary": "new summary", "status": "open"}}
    result = differ.compute_mutations(prev, next_)
    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "update"
    assert mutation["key"] == "DSO-3"
    assert mutation["fields"] == {"summary": "new summary"}


def test_update_contains_only_changed_fields(differ: ModuleType) -> None:
    prev = {"DSO-5": {"summary": "same", "status": "open", "priority": "low"}}
    next_ = {"DSO-5": {"summary": "same", "status": "closed", "priority": "low"}}
    result = differ.compute_mutations(prev, next_)
    assert len(result) == 1
    assert result[0]["fields"] == {"status": "closed"}
    assert "summary" not in result[0]["fields"]
    assert "priority" not in result[0]["fields"]


def test_excluded_field_not_in_update_payload(differ: ModuleType) -> None:
    # Change an excluded field alongside a real field — only the real field
    # should appear in the update payload.
    prev = {"DSO-9": {"summary": "before", "dso_local_id": "local-1", "dso-id": "id-1"}}
    next_ = {"DSO-9": {"summary": "after", "dso_local_id": "local-2", "dso-id": "id-2"}}
    result = differ.compute_mutations(prev, next_)
    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "update"
    assert "dso_local_id" not in mutation["fields"]
    assert "dso-id" not in mutation["fields"]
    assert mutation["fields"] == {"summary": "after"}


def test_create_excludes_excluded_fields(differ: ModuleType) -> None:
    # A new issue whose only fields are excluded should yield no mutation.
    prev: dict = {}
    next_ = {"DSO-11": {"dso_local_id": "loc", "dso-id": "xid"}}
    result = differ.compute_mutations(prev, next_)
    assert result == []


def test_create_with_mixed_fields_excludes_excluded_only(differ: ModuleType) -> None:
    prev: dict = {}
    next_ = {"DSO-12": {"summary": "keep me", "dso_local_id": "skip-me"}}
    result = differ.compute_mutations(prev, next_)
    assert len(result) == 1
    assert result[0]["fields"] == {"summary": "keep me"}
    assert "dso_local_id" not in result[0]["fields"]


def test_pure_function_invariant(differ: ModuleType) -> None:
    # Calling compute_mutations twice with the same inputs must return equal results.
    prev = {"DSO-1": {"summary": "hello"}, "DSO-2": {"summary": "world"}}
    next_ = {
        "DSO-1": {"summary": "hello updated"},
        "DSO-3": {"summary": "brand new"},
    }
    result_a = differ.compute_mutations(copy.deepcopy(prev), copy.deepcopy(next_))
    result_b = differ.compute_mutations(copy.deepcopy(prev), copy.deepcopy(next_))
    assert result_a == result_b


def test_mutations_are_sorted_by_key(differ: ModuleType) -> None:
    # The result should be in sorted key order for determinism.
    prev: dict = {}
    next_ = {
        "DSO-Z": {"summary": "z issue"},
        "DSO-A": {"summary": "a issue"},
        "DSO-M": {"summary": "m issue"},
    }
    result = differ.compute_mutations(prev, next_)
    keys = [m["key"] for m in result]
    assert keys == sorted(keys)
