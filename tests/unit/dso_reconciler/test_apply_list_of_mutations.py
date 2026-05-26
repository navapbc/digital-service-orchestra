"""Regression test for bug 1788-6149-e788-463f.

Pre-fix: applier.apply(mutations, pass_id, repo_root) crashed with
'Mutation' object has no attribute 'get' when `mutations` was a list of
Mutation dataclass instances (the canonical contract from epic 4047 / cde1).
The polymorphic dispatch in apply() handled "single Mutation" and "list of
dict" but not "list of Mutation" — the latter fell through to the legacy
_apply_batch which calls .get() on each element.

This test passes a list of Mutation instances to applier.apply() and asserts
it does NOT raise AttributeError; the call returns a manifest path (or any
non-exception result).
"""

import importlib.util
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
APPLIER_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "applier.py"
)
MUTATION_PATH = (
    REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "mutation.py"
)


def _load_canonical(name: str, path: Path):
    """Load a module under its canonical dotted key so production code that
    later resolves `plugins.dso.scripts.dso_reconciler.<name>` shares the
    object.
    """
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def applier_mod():
    """Load applier + mutation under canonical keys; clean up after."""
    saved = {
        k: sys.modules.pop(k, None)
        for k in list(sys.modules.keys())
        if "applier" in k or "mutation" in k
    }
    try:
        mut_mod = _load_canonical(
            "plugins.dso.scripts.dso_reconciler.mutation", MUTATION_PATH
        )
        applier = _load_canonical(
            "plugins.dso.scripts.dso_reconciler.applier", APPLIER_PATH
        )
        yield applier, mut_mod
    finally:
        for k in list(sys.modules.keys()):
            if "applier" in k or "mutation" in k:
                sys.modules.pop(k, None)
        for k, v in saved.items():
            if v is not None:
                sys.modules[k] = v


def test_apply_list_of_mutations_does_not_crash_with_get(applier_mod, tmp_path):
    """applier.apply called with list of Mutation dataclass instances must
    not raise AttributeError("'Mutation' object has no attribute 'get'").
    Regression: bug 1788-6149-e788-463f.
    """
    applier, mut_mod = applier_mod

    mutations = [
        mut_mod.Mutation(
            direction=mut_mod.MutationDirection.inbound,
            action=mut_mod.MutationAction.create,
            target="DIG-100",
            payload={
                "fields": {"summary": "test"},
                "local_id": "local-abc-123",
            },
            provenance={"source": "test"},
        ),
    ]

    # Pre-fix: this crashes inside _apply_batch with
    #   AttributeError: 'Mutation' object has no attribute 'get'
    # Post-fix: apply() normalizes Mutation→dict via _mutation_to_batch_dict
    # before delegating to _apply_batch.
    try:
        result = applier.apply(mutations, "test-pass-id", repo_root=tmp_path)
    except AttributeError as exc:
        if "'Mutation' object has no attribute" in str(exc):
            pytest.fail(
                f"Regression: applier.apply crashed on list-of-Mutation with "
                f"{exc!r}. The polymorphic dispatch must normalize Mutation "
                f"to dict before delegating to the legacy batch path."
            )
        raise
    except Exception as exc:
        # _apply_batch may raise other downstream errors (HEAD-pin drift,
        # client unavailable, etc.) — we only care that the .get crash is
        # gone. Other exceptions are acceptable for this regression test.
        if "'Mutation' object has no attribute" in str(exc):
            pytest.fail(f"Regression: nested .get failure: {exc!r}")
    else:
        # If we reach here, apply succeeded — manifest path was returned.
        assert result is not None
