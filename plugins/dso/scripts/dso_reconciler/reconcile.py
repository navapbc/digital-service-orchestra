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


class StatusMappingError(Exception):
    """Raised when a mutation references a local status absent from
    ``config.local_to_jira_status``. The preflight scan raises this before the
    applier dispatch loop runs so an unmapped status cannot be silently
    forwarded to Jira."""


def preflight_status_mapping(mutations) -> None:
    """Raise :class:`StatusMappingError` if any update mutation references a
    status absent from ``config.local_to_jira_status``.

    An empty mapping disables the scan (kill-switch). Non-update mutations and
    mutations whose ``fields`` payload does not include a ``status`` key are
    ignored.
    """
    cfg = _load("reconcile_config", "config.py")
    mapping = getattr(cfg, "local_to_jira_status", {}) or {}
    if not mapping:
        return  # kill-switch — empty mapping disables preflight
    for m in mutations:
        # Mutations may be plain dicts (current schema) or objects with an
        # ``.action`` attribute (forward-compat). Normalise to a string action.
        action_attr = getattr(m, "action", None)
        if action_attr is not None:
            action = getattr(action_attr, "value", action_attr)
            fields = getattr(m, "fields", None) or getattr(m, "payload", None) or {}
            target = getattr(m, "target", getattr(m, "key", None))
        else:
            action = m.get("action")
            fields = m.get("fields") or m.get("payload") or {}
            target = m.get("key") or m.get("local_id")
        if action != "update":
            continue
        if not isinstance(fields, dict):
            continue
        status = fields.get("status")
        if status and status not in mapping:
            raise StatusMappingError(
                f"local status {status!r} not in local_to_jira_status mapping "
                f"(target={target})"
            )


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

    # Read previous snapshot (empty dict on first pass); stable name ensures level-triggered convergence
    prev_path = snapshots_dir / "prev.json"
    prev_snapshot: dict = json.loads(prev_path.read_text()) if prev_path.exists() else {}

    # Fetch current remote state
    curr_path = fetcher.fetch_snapshot(pass_id, repo_root)
    curr_snapshot: dict = json.loads(curr_path.read_text())

    # Check structural invariants on the post-fetch snapshot, before diffing.
    # check_at_most_one_dso_local_id returns only the filed violations (capped
    # at 5 per pass — see invariants._CAP_PER_PASS), so the prior log line's
    # "violations" and "filed" numbers were identical by construction. F11: log
    # filed count with the cap for clarity.
    filed = invariants_mod.check_at_most_one_dso_local_id(
        curr_snapshot, repo_root=repo_root
    )
    print(  # noqa: T201
        f"invariants: scanned={len(curr_snapshot)} filed={len(filed)} (cap=5)"
    )

    # Invariant phase: verify dual-identity round-trip on the post-fetch
    # snapshot before diffing. Quarantine one-sided keys (skipped by the
    # differ) and seed repair_property mutations for one-sided dso_local_id
    # rows so the differ emits the repair in this same pass.
    quarantine_keys, seed_repair_property_mutations = (
        invariants_mod.check_dual_identity_complete(prev_snapshot, curr_snapshot)
    )

    # Compute mutations (pure function, no I/O). The invariant signals are
    # passed through so the differ honors quarantine + seed mutations.
    mutations = differ.compute_mutations(
        prev_snapshot,
        curr_snapshot,
        quarantine_set=quarantine_keys,
        seed_mutations=seed_repair_property_mutations,
    )

    # Post-emit filter: scan mutations for repair_property follow-ons that
    # carry a schema_drift kind (raised by the 44e6 repair_property failure
    # path). report_schema_drift surfaces each drift via stderr WARN so the
    # signal is not swallowed.
    for _m in mutations:
        if _m.get("action") != "repair_property":
            continue
        follow_on = _m.get("follow_on")
        if isinstance(follow_on, dict) and follow_on.get("kind") == "schema_drift":
            invariants_mod.report_schema_drift(
                follow_on.get("target"),
                follow_on.get("observed"),
                follow_on.get("expected"),
            )

    # Preflight: abort the pass if any update mutation references a status
    # not present in config.local_to_jira_status. Runs exactly once per pass,
    # before any applier dispatch, so unmapped statuses cannot reach Jira.
    preflight_status_mapping(mutations)

    # F8: wrap apply in try/except/finally so health.record_pass STILL fires
    # on apply failure with degraded fields (local_mutation_count=0,
    # failure_kind set). Without this wrapping, failed passes were invisible
    # to monitoring.
    manifest_path = None
    apply_exc: BaseException | None = None
    try:
        manifest_path = applier.apply(mutations, pass_id, repo_root)
    except BaseException as exc:  # noqa: BLE001 — must re-raise after recording
        apply_exc = exc
        raise
    finally:
        per_type_counts = health_mod.count_open_by_type(repo_root=repo_root)
        if apply_exc is None:
            health_mod.record_pass(
                pass_id=pass_id,
                pre_fsck=0,
                post_fsck=0,
                per_type_counts=per_type_counts,
                local_mutation_count=len(mutations),
                repo_root=repo_root,
            )
        else:
            # Classify the failure: reschedule vs generic apply error.
            failure_kind = (
                "reschedule"
                if type(apply_exc).__name__ == "RescheduleError"
                else "apply_error"
            )
            health_mod.record_pass(
                pass_id=pass_id,
                pre_fsck=0,
                post_fsck=0,
                per_type_counts=per_type_counts,
                local_mutation_count=0,
                repo_root=repo_root,
                failure_kind=failure_kind,
            )

    # Advance prev snapshot so the next call converges to zero mutations
    shutil.copy2(curr_path, prev_path)

    return {
        "pass_id": pass_id,
        "mutation_count": len(mutations),
        "manifest_path": str(manifest_path),
    }
