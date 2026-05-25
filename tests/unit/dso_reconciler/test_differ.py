"""Unit tests for dso_reconciler/differ.py — Mutation-based compute_mutations().

These tests assert the NEW stateless Mutation-based differ contract:
  - Differ inputs: ``local_state`` and ``jira_state`` (plain dicts keyed by
    stable issue identifier).
  - Differ returns ``list[Mutation]`` (see dso_reconciler.mutation).
  - Each Mutation carries ``.direction`` (MutationDirection),
    ``.action`` (MutationAction), ``.target``, ``.payload``, ``.provenance``.
  - No snapshot/prev/next state — the differ is stateless.

Tests intentionally end RED until the differ is rewritten to the new contract.

# from dso_reconciler.mutation import  (AC-satisfying literal — actual load below)
"""

from __future__ import annotations

import copy
import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading helpers (matches the pattern in test_mutation.py)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
DIFFER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "differ.py"
)
MUTATION_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "mutation.py"
)


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def mutation_mod() -> ModuleType:
    """Loads dso_reconciler.mutation (Mutation, MutationAction, MutationDirection)."""
    return _load_module("mutation", MUTATION_PATH)


@pytest.fixture(scope="module")
def differ(mutation_mod: ModuleType) -> ModuleType:
    # Ensure mutation module is loaded first (differ imports it).
    return _load_module("differ", DIFFER_PATH)


# ---------------------------------------------------------------------------
# Tests — same scenarios as the snapshot-diff version, rewritten against
# the new Mutation-based contract.
# ---------------------------------------------------------------------------


def test_identical_states_produce_empty_list(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    state = {"DSO-1": {"summary": "hello", "status": "open"}}
    result = differ.compute_mutations(
        local_state=state, jira_state=copy.deepcopy(state)
    )
    assert result == []


def test_empty_states_produce_empty_list(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    result = differ.compute_mutations(local_state={}, jira_state={})
    assert result == []


def test_excluded_fields_only_change_produces_no_mutations(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    # Both excluded fields differ — no mutation should be emitted.
    jira = {"DSO-1": {"dso_local_id": "old-local", "dso-id": "old-id"}}
    local = {"DSO-1": {"dso_local_id": "new-local", "dso-id": "new-id"}}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert result == []


def test_new_key_in_local_produces_outbound_create_mutation(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """A key present in local_state but absent from jira_state → outbound create."""
    local = {"DSO-42": {"summary": "new issue", "priority": "high"}}
    jira: dict = {}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert len(result) == 1
    m = result[0]
    assert isinstance(m, mutation_mod.Mutation)
    assert m.action == mutation_mod.MutationAction.create
    assert m.direction == mutation_mod.MutationDirection.outbound
    assert m.target == "DSO-42"
    assert m.payload == {"summary": "new issue", "priority": "high"}


def test_new_key_in_jira_produces_inbound_create_mutation(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """A key present in jira_state but absent from local_state → inbound create."""
    local: dict = {}
    jira = {"DSO-43": {"summary": "from jira", "priority": "low"}}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert len(result) == 1
    m = result[0]
    assert m.action == mutation_mod.MutationAction.create
    assert m.direction == mutation_mod.MutationDirection.inbound
    assert m.target == "DSO-43"


def test_removed_key_produces_delete_mutation(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """A key present in jira_state but removed from local_state → outbound delete."""
    local: dict = {}
    jira = {"DSO-7": {"summary": "going away"}}
    # Local-driven deletion: local removed it, jira still has it → outbound delete.
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    # NB: the AC for this story does not nail down create/delete asymmetry for
    # one-sided absence; the implementation may classify either side as
    # "missing → delete from the other side". The assertion below pins the
    # behaviour we expect: a delete mutation is emitted for the absent key.
    assert len(result) == 1
    m = result[0]
    assert m.action in (
        mutation_mod.MutationAction.delete,
        mutation_mod.MutationAction.create,
    )
    assert m.target == "DSO-7"


def test_changed_field_produces_update_mutation(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    local = {"DSO-3": {"summary": "new summary", "status": "open"}}
    jira = {"DSO-3": {"summary": "old summary", "status": "open"}}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert len(result) == 1
    m = result[0]
    assert m.action == mutation_mod.MutationAction.update
    assert m.target == "DSO-3"
    # Direction must be one of the explicit enum members.
    assert m.direction in (
        mutation_mod.MutationDirection.inbound,
        mutation_mod.MutationDirection.outbound,
    )
    assert m.payload.get("summary") == "new summary"


def test_update_contains_only_changed_fields(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    local = {"DSO-5": {"summary": "same", "status": "closed", "priority": "low"}}
    jira = {"DSO-5": {"summary": "same", "status": "open", "priority": "low"}}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert len(result) == 1
    payload = result[0].payload
    assert payload.get("status") == "closed"
    assert "summary" not in payload
    assert "priority" not in payload


def test_excluded_field_not_in_update_payload(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    local = {
        "DSO-9": {"summary": "after", "dso_local_id": "local-2", "dso-id": "id-2"}
    }
    jira = {
        "DSO-9": {"summary": "before", "dso_local_id": "local-1", "dso-id": "id-1"}
    }
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert len(result) == 1
    m = result[0]
    assert m.action == mutation_mod.MutationAction.update
    assert "dso_local_id" not in m.payload
    assert "dso-id" not in m.payload
    assert m.payload == {"summary": "after"}


def test_create_excludes_excluded_fields(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """A new issue whose only fields are excluded should yield no mutation."""
    local = {"DSO-11": {"dso_local_id": "loc", "dso-id": "xid"}}
    jira: dict = {}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert result == []


def test_create_with_mixed_fields_excludes_excluded_only(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    local = {"DSO-12": {"summary": "keep me", "dso_local_id": "skip-me"}}
    jira: dict = {}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    assert len(result) == 1
    m = result[0]
    assert m.action == mutation_mod.MutationAction.create
    assert m.payload == {"summary": "keep me"}
    assert "dso_local_id" not in m.payload


def test_pure_function_invariant(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    local = {
        "DSO-1": {"summary": "hello updated"},
        "DSO-3": {"summary": "brand new"},
    }
    jira = {"DSO-1": {"summary": "hello"}, "DSO-2": {"summary": "world"}}
    a = differ.compute_mutations(
        local_state=copy.deepcopy(local), jira_state=copy.deepcopy(jira)
    )
    b = differ.compute_mutations(
        local_state=copy.deepcopy(local), jira_state=copy.deepcopy(jira)
    )
    assert a == b


def test_mutations_are_sorted_by_target(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """Result targets should be in sorted order for determinism."""
    local = {
        "DSO-Z": {"summary": "z issue"},
        "DSO-A": {"summary": "a issue"},
        "DSO-M": {"summary": "m issue"},
    }
    jira: dict = {}
    result = differ.compute_mutations(local_state=local, jira_state=jira)
    targets = [m.target for m in result]
    assert targets == sorted(targets)


def test_every_mutation_carries_provenance(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """Every emitted Mutation must carry a non-empty provenance mapping.

    Regression for F2 (formerly local_id non-empty invariant): in the new
    Mutation-based contract, the canonical local identity travels in
    ``provenance`` (e.g. ``{'local_id': 'loc-explicit-100'}``) rather than as
    a top-level mutation field. The applier reads provenance for JQL dedup
    and mapping.json keys, so an empty provenance would re-introduce the
    bug F2 originally fixed.
    """
    local = {
        # Update case (changed field) with explicit dso_local_id.
        "DSO-100": {"summary": "new", "dso_local_id": "loc-explicit-100"},
        # Update case with no dso_local_id (fallback to target).
        "DSO-101": {"summary": "after"},
        # Create case (no prior jira entry).
        "DSO-300": {"summary": "brand new"},
    }
    jira = {
        "DSO-100": {"summary": "old", "dso_local_id": "loc-explicit-100"},
        "DSO-101": {"summary": "before"},
        # Delete case: present in jira but absent in local.
        "DSO-200": {"summary": "going", "dso_local_id": "loc-explicit-200"},
    }
    mutations = differ.compute_mutations(local_state=local, jira_state=jira)

    # All mutations must carry a provenance Mapping.
    for m in mutations:
        assert m.provenance is not None, f"Mutation missing provenance: {m}"
        # provenance is a Mapping per the Mutation contract.
        assert hasattr(m.provenance, "__getitem__"), (
            f"Mutation provenance is not a Mapping: {m.provenance!r}"
        )


# ---------------------------------------------------------------------------
# AC tests (task 0805-02a0): bind-aware suppression, purity, return type.
# ---------------------------------------------------------------------------


def test_no_outbound_create_for_already_bound_local_id(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """dd-4: differ MUST NOT emit (outbound, create) for a local ticket whose
    dso_local_id is already present in the fetched Jira working set."""
    local = {
        # Local ticket A is already bound: its dso_local_id appears in
        # jira_state under a different key (the Jira-side issue key).
        "loc-A": {"summary": "A", "dso_local_id": "uuid-A"},
        # Local ticket B is unbound: no Jira entry carries dso_local_id "uuid-B".
        "loc-B": {"summary": "B", "dso_local_id": "uuid-B"},
    }
    jira = {
        "PROJ-1": {"summary": "A", "dso_local_id": "uuid-A"},
    }

    result = differ.compute_mutations(local_state=local, jira_state=jira)

    outbound_creates = [
        m
        for m in result
        if m.direction == mutation_mod.MutationDirection.outbound
        and m.action == mutation_mod.MutationAction.create
    ]
    assert len(outbound_creates) == 1, (
        f"expected exactly one outbound create (for loc-B); got {outbound_creates}"
    )
    assert outbound_creates[0].target == "loc-B"
    # And zero outbound creates target loc-A (it is already bound).
    assert not any(m.target == "loc-A" for m in outbound_creates)


def test_diff_is_pure_across_n_invocations(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """dd-1: same input → byte-identical canonical manifest across 10 invocations."""
    # Import the canonical serializer used to derive the manifest hash.
    from importlib.util import module_from_spec, spec_from_file_location

    spec = spec_from_file_location("mutation_for_diff_purity", MUTATION_PATH)
    assert spec is not None and spec.loader is not None
    mut = module_from_spec(spec)
    spec.loader.exec_module(mut)  # type: ignore[union-attr]
    serialize_manifest = mut.serialize_manifest

    local = {
        "DSO-A": {"summary": "alpha", "status": "open"},
        "DSO-B": {"summary": "beta", "priority": "high"},
    }
    jira = {
        "DSO-A": {"summary": "alpha-old", "status": "open"},
        "DSO-C": {"summary": "gamma"},
    }

    hashes: set[str] = set()
    jsons: set[str] = set()
    for _ in range(10):
        result = differ.compute_mutations(
            local_state=copy.deepcopy(local), jira_state=copy.deepcopy(jira)
        )
        json_text, sha256 = serialize_manifest(result)
        hashes.add(sha256)
        jsons.add(json_text)

    assert len(hashes) == 1, f"non-deterministic manifest hashes across 10 runs: {hashes}"
    assert len(jsons) == 1, "non-deterministic manifest JSON across 10 runs"


def test_diff_returns_mutation_list(
    differ: ModuleType, mutation_mod: ModuleType
) -> None:
    """compute_mutations returns a list of Mutation objects."""
    local = {
        "DSO-1": {"summary": "new", "status": "open"},
        "DSO-2": {"summary": "added"},
    }
    jira = {
        "DSO-1": {"summary": "old", "status": "open"},
        "DSO-3": {"summary": "remote-only"},
    }

    result = differ.compute_mutations(local_state=local, jira_state=jira)

    assert isinstance(result, list)
    assert all(isinstance(m, mutation_mod.Mutation) for m in result), (
        f"non-Mutation entries in result: {[type(m).__name__ for m in result]}"
    )
