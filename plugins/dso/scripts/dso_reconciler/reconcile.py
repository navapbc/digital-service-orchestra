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
from collections.abc import Mapping
from typing import Any


# ---------------------------------------------------------------------------
# Typed-mutation dispatch table
#
# Maps (direction_value: str, action_value: str) → leaf callable from applier.
# Built lazily at first call to _dispatch_mutation so that top-level import of
# reconcile.py does NOT pull in applier (preserves the existing test invariant:
# test_import_does_not_load_fetcher / T3's import-topology guard).
#
# INVALID_PAIRS lists (direction, action) string pairs that are NOT routed by
# the dispatch table and are NOT in mutation._VALID_COMBINATIONS — pairs that
# neither direction has semantics for.  Currently empty because _VALID_COMBINATIONS
# already excludes the two inbound-only actions from the outbound direction;
# the dispatch table is built solely from _VALID_COMBINATIONS.
# ---------------------------------------------------------------------------

INVALID_PAIRS: frozenset[tuple[str, str]] = frozenset(
    {
        ("outbound", "clean_label"),
        ("outbound", "repair_property"),
    }
)
"""String (direction, action) pairs with no valid dispatch arm and no applier semantics.

These two pairs are inbound-only actions: clean_label and repair_property have no
outbound semantics (they only apply to Jira-side data corrections).  The pairs are
excluded from mutation._VALID_COMBINATIONS by _INBOUND_ONLY_ACTIONS; they are listed
here so the enumerative coverage test can verify completeness of the dispatch table
over the full {inbound, outbound} × MutationAction cartesian product.
"""

_DISPATCH_TABLE: dict[tuple[str, str], object] | None = None


def _build_dispatch_table() -> dict[tuple[str, str], object]:
    """Build and return the (direction_str, action_str) → leaf callable mapping.

    Loads the applier module via ``_load()`` (the same lazy-loader used by
    ``reconcile_once``) so that applier.py is NOT imported at reconcile
    module-load time, preserving the import topology invariant tested in
    test_reconcile_main.py.  Fetching the leaf functions via ``getattr``
    after the module load avoids relative imports, which cannot resolve when
    reconcile.py is loaded via ``importlib.util.spec_from_file_location``
    outside of a package context (as in the unit-test harness).
    """
    applier = _load("reconcile_applier", "applier.py")

    return {
        ("inbound", "create"): getattr(applier, "_apply_inbound_create"),
        ("inbound", "update"): getattr(applier, "_apply_inbound_update"),
        ("inbound", "delete"): getattr(applier, "_apply_inbound_delete"),
        ("inbound", "probe"): getattr(applier, "_apply_inbound_probe"),
        ("inbound", "clean_label"): getattr(applier, "_apply_inbound_clean_label"),
        ("inbound", "repair_property"): getattr(
            applier, "_apply_inbound_repair_property"
        ),
        ("inbound", "conflict"): getattr(applier, "_apply_inbound_conflict"),
        ("outbound", "create"): getattr(applier, "_apply_outbound_create"),
        ("outbound", "update"): getattr(applier, "_apply_outbound_update"),
        ("outbound", "delete"): getattr(applier, "_apply_outbound_delete"),
        ("outbound", "probe"): getattr(applier, "_apply_outbound_probe"),
        ("outbound", "conflict"): getattr(applier, "_apply_outbound_conflict"),
    }


def _dispatch_mutation(mutation: Any, context: Any = None) -> Any:
    """Route a typed Mutation to its leaf handler in the applier.

    Dispatches based on (mutation.direction, mutation.action) string values
    via the module-level ``_DISPATCH_TABLE``.  The table is built lazily on
    the first call to avoid pulling applier into the import graph at module
    load time.

    Args:
        mutation: A ``mutation.Mutation`` (or duck-typed object with
                  ``.direction`` and ``.action`` string-valued attributes).
        context:  Optional call context forwarded to the leaf (currently
                  unused by stub leaves; reserved for client injection).

    Returns:
        The ``ApplyResult`` returned by the matching leaf callable.

    Raises:
        NotImplementedError: When (direction, action) is not in the dispatch
            table, naming the tuple in the message so callers can identify
            the unhandled pair.
    """
    global _DISPATCH_TABLE
    if _DISPATCH_TABLE is None:
        _DISPATCH_TABLE = _build_dispatch_table()

    d = str(getattr(mutation.direction, "value", mutation.direction))
    a = str(getattr(mutation.action, "value", mutation.action))
    key = (d, a)

    leaf = _DISPATCH_TABLE.get(key)
    if leaf is None:
        raise NotImplementedError(
            f"no dispatch arm for (direction={d!r}, action={a!r})"
        )
    return leaf(mutation, client=context)


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


def _audit_log_probe(
    branch_label: str, issue_key: str, detail: dict | None = None
) -> None:
    """Write a single audit-log entry to stderr for log-only probe branches.

    Used by :func:`route_inbound_probe` for branches that produce no follow-on
    mutation (``trash_restore`` / PRESENT_RESOLVED and ``unreachable`` /
    UNREACHABLE) so that the probe outcome is still durably observable in
    pass logs.
    """
    detail_str = "" if not detail else f" detail={detail!r}"
    print(  # noqa: T201
        f"inbound_probe: branch={branch_label} key={issue_key}{detail_str}"
    )


def route_inbound_probe(mutation: Any, probe_result: Any) -> list[Any] | None:
    """Route an (inbound, probe) Mutation to a branch-specific follow-on.

    Branches:
      * ARCHIVED_OR_MOVED → ``hard_delete`` — emit ``(inbound, delete, target)``
        follow-on targeting the local jira-<key> partner. Provenance records
        the original probe target and the probe status_code.
      * PRESENT_RESOLVED  → ``trash_restore`` — NO follow-on; write one audit
        log entry with branch=``trash_restore`` and the issue key.
      * PRESENT_FILTERED  → currently no emission. The basic 4-branch
        classifier does not distinguish ``project_move`` from generic
        ``trash_restore``-filtered; a future enhancement may inspect
        ``probe_result.detail`` for a ``new_project_key`` signal and emit a
        reparent follow-on. For now, log and emit no follow-on.
      * UNREACHABLE       → NO follow-on; audit log entry with
        branch=``unreachable``.

    Args:
        mutation:     The (inbound, probe) Mutation under inspection.
        probe_result: An :class:`inbound_probe.ProbeResult`.

    Returns:
        A list of follow-on Mutations (possibly empty) for branches that
        emit follow-ons, or ``None`` for log-only branches.
    """
    # Lazy-load probe + mutation modules to avoid import cycles at module top.
    probe_mod = _load("inbound_probe", "inbound_probe.py")
    mut_mod = _load("reconcile_mutation", "mutation.py")

    branch = probe_result.branch
    target = probe_result.issue_key

    if branch == probe_mod.ProbeBranch.ARCHIVED_OR_MOVED:
        follow_on = mut_mod.Mutation(
            direction=mut_mod.MutationDirection.inbound,
            action=mut_mod.MutationAction.delete,
            target=target,
            payload={
                "reason": "hard_delete",
                "probe_detail": dict(probe_result.detail),
            },
            provenance={
                "source": "inbound_probe_dispatch",
                "branch": "hard_delete",
                "origin_target": getattr(mutation, "target", target),
            },
        )
        return [follow_on]

    if branch == probe_mod.ProbeBranch.PRESENT_RESOLVED:
        _audit_log_probe("trash_restore", target, dict(probe_result.detail))
        return None

    if branch == probe_mod.ProbeBranch.PRESENT_FILTERED:
        # No follow-on for generic filtered branch under the 4-branch classifier.
        # Future enhancement: detect project_move via probe_result.detail.
        _audit_log_probe("present_filtered", target, dict(probe_result.detail))
        return None

    if branch == probe_mod.ProbeBranch.UNREACHABLE:
        _audit_log_probe("unreachable", target, dict(probe_result.detail))
        return None

    # Defensive fallback for unknown branch values.
    _audit_log_probe(f"unknown:{branch!r}", target, dict(probe_result.detail))
    return None


def reconcile_once(
    pass_id: str, repo_root: Path | None = None, target_mode=None
) -> dict:
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
    prev_snapshot: dict = (
        json.loads(prev_path.read_text()) if prev_path.exists() else {}
    )

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
    # carry a schema_drift kind. report_schema_drift surfaces each drift via
    # stderr WARN so the signal is not swallowed.
    #
    # CONTRACT NOTE: applier.inbound_repair_property emits follow-ons with
    # kind="schema_drift_signal" (see applier.py:1142), but this loop matches
    # kind=="schema_drift". The naming mismatch means follow-ons produced
    # from the in-pass repair_property failure path are NOT picked up here.
    # The current consumers of this filter are the differ + test fixtures
    # that emit kind="schema_drift" directly. Aligning these is tracked
    # separately under meta-bug 5f2a-9a9f-2b4a-4aab.
    #
    # Mutations may be plain dicts (legacy schema) or Mutation dataclass
    # instances (canonical contract from epic 4047 / cde1). Normalise on
    # access — mirrors the same dual-shape pattern in
    # preflight_status_mapping below. Pre-fix this loop used
    # `_m.get("action")` which crashed with "'Mutation' object has no
    # attribute 'get'" once the reconciler reached this code path in
    # production with typed Mutations.
    mut_mod_for_action = _load("reconcile_mutation", "mutation.py")
    for _m in mutations:
        action_attr = getattr(_m, "action", None)
        if action_attr is not None:
            # Typed Mutation shape. Normalise enum/string for comparison.
            action_str = getattr(action_attr, "value", action_attr)
            payload = getattr(_m, "payload", None) or {}
            follow_on = (
                payload.get("follow_on") if isinstance(payload, Mapping) else None
            )
        else:
            # Legacy dict shape.
            action_str = _m.get("action")
            follow_on = _m.get("follow_on")
        if action_str != mut_mod_for_action.MutationAction.repair_property.value:
            continue
        if isinstance(follow_on, Mapping) and follow_on.get("kind") == "schema_drift":
            invariants_mod.report_schema_drift(
                follow_on.get("target"),
                follow_on.get("observed"),
                follow_on.get("expected"),
            )

    # Inbound-probe dispatch: any (inbound, probe) Mutation emitted by the
    # differ is routed through the live inbound_probe classifier, then
    # converted into a branch-specific follow-on (or a log-only outcome) via
    # route_inbound_probe. Follow-on mutations are appended in-place so the
    # applier dispatches them in the same pass.
    mut_mod = _load("reconcile_mutation", "mutation.py")
    probe_mod = _load("inbound_probe", "inbound_probe.py")
    probe_follow_ons: list = []
    for _m in mutations:
        # Only Mutation objects with the (inbound, probe) combo trigger a probe.
        direction = getattr(_m, "direction", None)
        action = getattr(_m, "action", None)
        if direction is None or action is None:
            continue
        if direction != mut_mod.MutationDirection.inbound:
            continue
        if action != mut_mod.MutationAction.probe:
            continue
        try:
            probe_result = probe_mod.probe(_m.target)
        except probe_mod.ProbeConfigError as exc:
            # Missing env → treat as unreachable; do not abort the pass.
            print(  # noqa: T201
                f"inbound_probe: skipped key={_m.target} reason=config_error err={exc}",
                file=sys.stderr,
            )
            continue
        follow_ons = route_inbound_probe(_m, probe_result)
        if follow_ons:
            probe_follow_ons.extend(follow_ons)
    if probe_follow_ons:
        mutations.extend(probe_follow_ons)

    # Preflight: abort the pass if any update mutation references a status
    # not present in config.local_to_jira_status. Runs exactly once per pass,
    # before any applier dispatch, so unmapped statuses cannot reach Jira.
    preflight_status_mapping(mutations)

    # F8: wrap apply in try/except/finally so health.record_pass STILL fires
    # on apply failure with degraded fields (local_mutation_count=0,
    # failure_kind set). Without this wrapping, failed passes were invisible
    # to monitoring.
    #
    # Direction-aware dispatch lives inside applier.apply (PR #371 / defect
    # #8): the applier partitions typed Mutations by direction internally and
    # routes inbound via _apply_typed per-mutation, outbound via the batch
    # path. The previous reconcile_once-level typed/legacy split (commit
    # cb858e468d) was a parallel workaround for the same gap; with cap
    # enforcement landing in applier.apply (story 286b), all mutations must
    # flow through that single entry point so caps apply uniformly across
    # both directions. `_dispatch_mutation` is preserved as a public seam
    # for tests/test_dispatch_coverage.py — it is no longer called from
    # reconcile_once.
    manifest_path = None
    apply_exc: BaseException | None = None
    try:
        # Backward compatibility: tests stub applier.apply with a signature
        # that does not accept the `mode` kwarg. Only pass it when caller
        # actually supplied a target_mode (i.e., when cap enforcement is
        # requested).
        if target_mode is None:
            manifest_path = applier.apply(mutations, pass_id, repo_root)
        else:
            manifest_path = applier.apply(
                mutations, pass_id, repo_root, mode=target_mode
            )
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
