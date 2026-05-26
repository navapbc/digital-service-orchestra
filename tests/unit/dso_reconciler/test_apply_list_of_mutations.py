"""Regression tests for bug 1788-6149-e788-463f.

`applier.apply(list[Mutation], pass_id, repo_root)` previously crashed with
'Mutation' object has no attribute 'get' when fed Mutation dataclass
instances — the polymorphic dispatch fell through to `_apply_batch` which
calls `.get()` on each element.

These tests stub `_apply_batch` and assert observable behavior:
  1. list-of-Mutation reaches _apply_batch as list-of-DICT (no Mutation
     instances leak through).
  2. Each dict has the keys _apply_batch expects (action / fields / key /
     local_id / follow_on / direction) and ONLY JSON-serializable values.
  3. Empty payload.fields preserves the empty dict (does not truthy-fall
     through to the whole payload).
  4. Inbound typed Mutations raise TypeError rather than silently routing
     through outbound batch handlers (fail-closed guard).
"""

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
)
MUTATION_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "mutation.py"
)

# Narrow set of sys.modules keys this test owns. Other tests' modules are
# not evicted so they don't suffer cross-test interference.
_OWNED_KEYS = (
    "plugins.dso.scripts.dso_reconciler.applier",
    "plugins.dso.scripts.dso_reconciler.mutation",
)


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def applier_and_mutation():
    """Load applier + mutation under canonical keys. Clean up only the
    specific keys this test installs (NOT any module containing "applier"
    or "mutation" in its name — that was too broad and risked cross-test
    interference).
    """
    saved = {k: sys.modules.pop(k, None) for k in _OWNED_KEYS}
    try:
        mut_mod = _load(_OWNED_KEYS[1], MUTATION_PATH)
        applier = _load(_OWNED_KEYS[0], APPLIER_PATH)
        yield applier, mut_mod
    finally:
        for k in _OWNED_KEYS:
            sys.modules.pop(k, None)
        for k, v in saved.items():
            if v is not None:
                sys.modules[k] = v


def _make_outbound_create(mut_mod, target="DIG-100", payload=None):
    return mut_mod.Mutation(
        direction=mut_mod.MutationDirection.outbound,
        action=mut_mod.MutationAction.create,
        target=target,
        payload=payload or {"fields": {"summary": "test"}, "local_id": "local-abc"},
        provenance={"source": "test"},
    )


def test_list_of_mutation_normalized_to_dict_before_apply_batch(
    applier_and_mutation, tmp_path
):
    """applier.apply([Mutation], ...) must pass list-of-dict (not list-of-
    Mutation) to _apply_batch. Assert observable behavior: _apply_batch
    is called with dicts having the expected keys; no Mutation leaks.
    """
    applier, mut_mod = applier_and_mutation
    mutations = [_make_outbound_create(mut_mod)]

    with patch.object(applier, "_apply_batch", return_value=tmp_path / "m.json") as ab:
        applier.apply(mutations, "pass-1", repo_root=tmp_path)

    assert ab.call_count == 1
    passed_list = ab.call_args[0][0]
    assert isinstance(passed_list, list)
    assert all(isinstance(m, dict) for m in passed_list), (
        f"Mutation leaked through: {[type(m).__name__ for m in passed_list]}"
    )
    assert all("action" in m and "key" in m for m in passed_list), (
        "normalized dicts missing required batch keys"
    )


def test_normalized_dict_is_json_serializable(applier_and_mutation, tmp_path):
    """Every value in the normalized dict must be JSON-serializable —
    _apply_batch later writes the manifest via json.dumps. A non-
    serializable value (e.g. a Mutation back-reference) would crash there.
    """
    applier, mut_mod = applier_and_mutation
    mutations = [_make_outbound_create(mut_mod)]

    with patch.object(applier, "_apply_batch", return_value=tmp_path / "m.json") as ab:
        applier.apply(mutations, "pass-2", repo_root=tmp_path)

    passed_list = ab.call_args[0][0]
    for m in passed_list:
        try:
            json.dumps(m)
        except TypeError as exc:
            pytest.fail(
                f"normalized dict is not JSON-serializable ({exc}); "
                f"a non-serializable value (e.g. Mutation back-ref) would "
                f"crash _apply_batch's manifest write"
            )


def test_empty_fields_does_not_fall_through_to_full_payload(
    applier_and_mutation, tmp_path
):
    """payload.get('fields', payload) — NOT `or payload`. An intentionally
    empty fields dict must reach _apply_batch as {} (not as the full
    payload), to prevent leaking local_id / follow_on into batch fields.
    """
    applier, mut_mod = applier_and_mutation
    mutations = [
        _make_outbound_create(
            mut_mod,
            payload={"fields": {}, "local_id": "L1", "follow_on": {"kind": "x"}},
        ),
    ]

    with patch.object(applier, "_apply_batch", return_value=tmp_path / "m.json") as ab:
        applier.apply(mutations, "pass-3", repo_root=tmp_path)

    passed_list = ab.call_args[0][0]
    assert passed_list[0]["fields"] == {}, (
        f"empty fields fell through to full payload: {passed_list[0]['fields']!r}"
    )
    # local_id / follow_on still preserved as top-level keys
    assert passed_list[0]["local_id"] == "L1"
    assert passed_list[0]["follow_on"] == {"kind": "x"}


def test_inbound_mutation_raises_typeerror_not_silent_outbound_routing(
    applier_and_mutation, tmp_path
):
    """Fail-closed guard: passing an inbound typed Mutation to the legacy
    batch path must RAISE TypeError, not silently route through outbound
    handlers. Inbound dispatch is per-mutation via reconcile._dispatch_mutation.
    """
    applier, mut_mod = applier_and_mutation
    inbound_mutations = [
        mut_mod.Mutation(
            direction=mut_mod.MutationDirection.inbound,
            action=mut_mod.MutationAction.create,
            target="local-abc",
            payload={"fields": {}, "local_id": "local-abc"},
            provenance={"source": "test"},
        ),
    ]

    with patch.object(applier, "_apply_batch") as ab:
        with pytest.raises(TypeError, match="inbound"):
            applier.apply(inbound_mutations, "pass-4", repo_root=tmp_path)
        # _apply_batch was NEVER called — guard fired before normalisation
        assert ab.call_count == 0


# ---------------------------------------------------------------------------
# Coverage gaps flagged by PR #364 cycle 3 llm-review (rolled into follow-on)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("empty_value", [[], None])
def test_apply_with_empty_or_none_mutations_passes_empty_list(
    applier_and_mutation, tmp_path, empty_value
):
    """`apply(None | [], pass_id, repo_root)` reaches _apply_batch with an
    empty list — not a crash or a None. Line 1236 normalizes via
    `list(mutations or [])`; both inputs must produce []."""
    applier, _ = applier_and_mutation
    with patch.object(applier, "_apply_batch", return_value=tmp_path / "m.json") as ab:
        applier.apply(empty_value, "pass-empty", repo_root=tmp_path)
    assert ab.call_count == 1
    assert ab.call_args[0][0] == [], (
        f"empty/None mutations did not normalize to []: {ab.call_args[0][0]!r}"
    )


def test_apply_with_all_dict_legacy_format_skips_normalization(
    applier_and_mutation, tmp_path
):
    """When mutations is entirely legacy-format dicts (no Mutation objects),
    the any(_looks_like_mutation) guard evaluates False and dicts pass
    directly to _apply_batch unchanged. This is the documented contract path
    pre-dating the Mutation epic."""
    applier, _ = applier_and_mutation
    legacy_dicts = [
        {"action": "create", "key": "DIG-1", "fields": {"summary": "a"}},
        {"action": "update", "key": "DIG-2", "fields": {"summary": "b"}},
    ]
    with patch.object(applier, "_apply_batch", return_value=tmp_path / "m.json") as ab:
        applier.apply(legacy_dicts, "pass-legacy", repo_root=tmp_path)
    passed_list = ab.call_args[0][0]
    # Each element is the SAME object as the input — no normalization ran.
    assert passed_list[0] is legacy_dicts[0], "legacy dict was unexpectedly transformed"
    assert passed_list[1] is legacy_dicts[1], "legacy dict was unexpectedly transformed"


def test_mutation_to_batch_dict_handles_empty_payload(applier_and_mutation, tmp_path):
    """`_mutation_to_batch_dict` with an empty-but-non-None payload must not
    crash. The Mutation contract (mutation.py:__post_init__) rejects None
    payloads, so the `if mutation.payload else {}` branch in
    _mutation_to_batch_dict is defense-in-depth for falsy mappings ({}),
    not for None — this test pins the empty-dict path."""
    applier, mut_mod = applier_and_mutation
    mutation_empty_payload = mut_mod.Mutation(
        direction=mut_mod.MutationDirection.outbound,
        action=mut_mod.MutationAction.create,
        target="DIG-999",
        payload={},
        provenance={"source": "test"},
    )
    with patch.object(applier, "_apply_batch", return_value=tmp_path / "m.json") as ab:
        applier.apply([mutation_empty_payload], "pass-empty-payload", repo_root=tmp_path)
    passed = ab.call_args[0][0][0]
    assert passed["fields"] == {}
    assert passed["key"] == "DIG-999"
    assert passed["action"] == "create"
    assert passed["local_id"] == ""
    assert passed["follow_on"] is None
