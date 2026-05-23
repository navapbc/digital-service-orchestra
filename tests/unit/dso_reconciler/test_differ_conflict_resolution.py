"""Unit tests for conflict resolution wiring in differ.py compute_mutations().

Tests cover:
  - test_state_field_local_wins: status diverges (local "In Progress", remote "Done")
    → mutation uses local value "In Progress" via resolve_state.
  - test_set_field_union_resolution: labels diverge (local ["X","Y"], remote ["Y","Z"])
    → mutation contains union of all three labels.
  - test_non_field_class_field_uses_raw_local: field not in FIELD_CLASSES still
    appears in the mutation with the local (next_snapshot) value, no resolution.
"""

from __future__ import annotations

import importlib.util
import sys
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
CONFLICT_RESOLVER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "conflict_resolver.py"
)


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def differ() -> ModuleType:
    return _load_module("differ", DIFFER_PATH)


@pytest.fixture(scope="module")
def conflict_resolver() -> ModuleType:
    return _load_module("conflict_resolver", CONFLICT_RESOLVER_PATH)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_state_field_local_wins(differ: ModuleType, conflict_resolver: ModuleType) -> None:
    """When 'status' diverges, resolve_state picks local (next_snapshot) value.

    prev_snapshot represents the remote/prior state; next_snapshot is local.
    Local "In Progress" should win over remote "Done".
    """
    prev = {"DSO-1": {"status": "Done"}}
    next_ = {"DSO-1": {"status": "In Progress"}}

    result = differ.compute_mutations(prev, next_)

    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "update"
    assert mutation["key"] == "DSO-1"
    # resolve_state: local wins → "In Progress"
    assert mutation["fields"]["status"] == "In Progress"


def test_set_field_union_resolution(differ: ModuleType, conflict_resolver: ModuleType) -> None:
    """When 'labels' diverges, resolve_set_valued returns union of both sets.

    local ["X", "Y"], remote ["Y", "Z"] → resolved contains X, Y, and Z.
    """
    prev = {"DSO-2": {"labels": ["Y", "Z"]}}   # remote/prior
    next_ = {"DSO-2": {"labels": ["X", "Y"]}}  # local

    result = differ.compute_mutations(prev, next_)

    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "update"
    assert mutation["key"] == "DSO-2"
    resolved_labels = mutation["fields"]["labels"]
    assert set(resolved_labels) == {"X", "Y", "Z"}


def test_non_field_class_field_uses_raw_local(differ: ModuleType, conflict_resolver: ModuleType) -> None:
    """A field not in FIELD_CLASSES still appears in the mutation with local value.

    No conflict resolution is applied; compute_mutations uses the next_snapshot
    (local) value directly, which is the existing behaviour.
    """
    field_name = "summary"  # not in FIELD_CLASSES
    assert field_name not in conflict_resolver.FIELD_CLASSES

    prev = {"DSO-3": {field_name: "old summary"}}
    next_ = {"DSO-3": {field_name: "new summary"}}

    result = differ.compute_mutations(prev, next_)

    assert len(result) == 1
    mutation = result[0]
    assert mutation["action"] == "update"
    assert mutation["key"] == "DSO-3"
    assert mutation["fields"][field_name] == "new summary"
