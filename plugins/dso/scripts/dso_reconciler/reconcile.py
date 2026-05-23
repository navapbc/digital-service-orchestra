#!/usr/bin/env python3
"""reconcile.py — one-pass orchestrator: fetch → diff → apply.

reconcile_once(pass_id) wires the three reconciler stages into a single
idempotent pass.  Two consecutive calls with an unchanged remote produce
mutation_count=0 on both passes (second call sees prev==curr snapshot).
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import sys
from pathlib import Path


def _load(name: str, relpath: str):
    """Load a sibling module by relative file path, registering it in sys.modules.

    Returns the cached module when ``name`` is already in ``sys.modules``;
    this allows test fixtures to pre-register patched modules and have
    ``reconcile_once`` reuse them rather than loading fresh copies.
    """
    if name in sys.modules:
        return sys.modules[name]
    path = Path(__file__).parent / relpath
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def reconcile_once(pass_id: str, repo_root: Path | None = None) -> dict:
    """Run one reconciler pass: fetch → diff → apply.

    Reads the previous snapshot (written at the end of the prior pass) from
    ``bridge_state/snapshots/<pass_id>.prev.json``, fetches the current
    remote state, computes mutations, applies them, then advances the prev
    snapshot file so the next call is idempotent against an unchanged remote.

    Args:
        pass_id:   Unique identifier for this reconciliation pass.
        repo_root: Repository root directory.  Defaults to four levels above
                   this file (dso_reconciler/ → scripts/ → dso/ → plugins/ →
                   repo root).

    Returns:
        ``{"pass_id": pass_id, "mutation_count": N, "manifest_path": str}``
        where N is the number of mutations dispatched in this pass.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]

    fetcher = _load("reconcile_fetcher", "fetcher.py")
    differ = _load("reconcile_differ", "differ.py")
    applier = _load("reconcile_applier", "applier.py")
    health_mod = _load("reconcile_health", "health.py")
    invariants_mod = _load("reconcile_invariants", "invariants.py")

    # Ensure snapshots directory exists
    snapshots_dir = repo_root / "bridge_state" / "snapshots"
    snapshots_dir.mkdir(parents=True, exist_ok=True)

    # Read previous snapshot (empty dict on first pass)
    prev_path = snapshots_dir / f"{pass_id}.prev.json"
    prev_snapshot: dict = json.loads(prev_path.read_text()) if prev_path.exists() else {}

    # Fetch current remote state
    curr_path = fetcher.fetch_snapshot(pass_id, repo_root)
    curr_snapshot: dict = json.loads(curr_path.read_text())

    # Check structural invariants on the post-fetch snapshot, before diffing
    violations = invariants_mod.check_at_most_one_dso_local_id(
        curr_snapshot, repo_root=repo_root
    )
    filed = violations  # check_at_most_one_dso_local_id returns only the filed violations
    print(  # noqa: T201
        f"invariants: scanned={len(curr_snapshot)} violations={len(filed)} filed={len(filed)}"
    )

    # Compute mutations (pure function, no I/O)
    mutations = differ.compute_mutations(prev_snapshot, curr_snapshot)

    # Apply mutations and write manifest
    manifest_path = applier.apply(mutations, pass_id, repo_root)

    # Record pass health metrics (pre_fsck/post_fsck/per_type_counts are
    # placeholders until task aa2b wires capture_baseline()).
    health_mod.record_pass(
        pass_id=pass_id,
        pre_fsck=0,
        post_fsck=0,
        per_type_counts={},
        local_mutation_count=len(mutations),
        repo_root=repo_root,
    )

    # Advance prev snapshot so the next call converges to zero mutations
    shutil.copy2(curr_path, prev_path)

    return {
        "pass_id": pass_id,
        "mutation_count": len(mutations),
        "manifest_path": str(manifest_path),
    }
