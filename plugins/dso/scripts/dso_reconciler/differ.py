"""Pure-function differ for dso_reconciler.

Compares the local source-of-truth state against the Jira working-set state and
emits a deterministic list of Mutation objects describing the reconciliation
work to perform.

This module replaces the legacy snapshot-diff contract
(``compute_mutations(prev_snapshot, next_snapshot) -> list[dict]``) with the
new Mutation-based contract:

    compute_mutations(local_state, jira_state) -> list[Mutation]

Fields listed in ``EXCLUDED_FIELDS`` (from ``config.py``) are ignored during
field-level comparison and never appear in a Mutation's payload.

The function is pure: no I/O, no time/random, no logging, no globals.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any


def _load_sibling(module_name: str, file_name: str) -> ModuleType:
    """Load a sibling module under a stable cache key without PYTHONPATH."""
    sibling_path = Path(__file__).parent / file_name
    cache_key = f"dso_reconciler_{module_name}"
    spec = importlib.util.spec_from_file_location(cache_key, sibling_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(cache_key, mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _load_config() -> ModuleType:
    return _load_sibling("config", "config.py")


def _load_conflict_resolver() -> ModuleType:
    return _load_sibling("conflict_resolver", "conflict_resolver.py")


def _load_mutation() -> ModuleType:
    # Prefer an already-loaded mutation module to preserve class identity
    # across callers (tests load mutation.py under the bare "mutation" key;
    # producing a second class object under a different cache key would
    # break isinstance() checks even though the source is identical).
    for cache_key in ("mutation", "dso_reconciler.mutation", "dso_reconciler_mutation"):
        cached = sys.modules.get(cache_key)
        if cached is not None and hasattr(cached, "Mutation"):
            return cached
    return _load_sibling("mutation", "mutation.py")


def _derive_provenance(
    target: str,
    primary_fields: dict[str, Any] | None,
    fallback_fields: dict[str, Any] | None,
    reason: str,
) -> dict[str, Any]:
    """Build a non-empty provenance Mapping for a Mutation.

    Always carries ``source`` and ``reason``. Adds ``local_id`` derived from
    the snapshot's ``dso_local_id`` (with fallback) so downstream applier
    paths (JQL dedup, mapping.json lookup) have a non-empty key. The
    jira_key is used as a last-resort fallback — fixes F2 where empty
    local_id collapsed dedup and corrupted mapping.json.
    """
    local_id: str | None = None
    if isinstance(primary_fields, dict):
        cand = primary_fields.get("dso_local_id")
        if cand:
            local_id = str(cand)
    if local_id is None and isinstance(fallback_fields, dict):
        cand = fallback_fields.get("dso_local_id")
        if cand:
            local_id = str(cand)
    if local_id is None:
        local_id = target
    return {"source": "differ", "reason": reason, "local_id": local_id}


def _emit(
    mutation: Any,
    *,
    quarantine_set: set[str] | None,
    mutations_out: list[Any],
) -> None:
    """Central emit gate for all Mutation appends in compute_mutations().

    Suppresses any mutation whose ``target`` is in ``quarantine_set``. When
    ``quarantine_set`` is None, every mutation is appended unconditionally.

    All Mutation-emit sites in :func:`compute_mutations` MUST route through
    this helper so the quarantine policy is enforced in exactly one place.
    """
    if quarantine_set is not None and mutation.target in quarantine_set:
        return
    mutations_out.append(mutation)


def compute_mutations(
    local_state: dict[str, dict] | None = None,
    jira_state: dict[str, dict] | None = None,
    *,
    quarantine_set: set[str] | None = None,
    seed_mutations: list[Any] | None = None,
) -> list[Any]:
    """Diff local against jira state and return a list of Mutation objects.

    Args:
        local_state: ``{key: {field: value, ...}}`` — the local source of
            truth (e.g. the ticket tracker snapshot).
        jira_state: ``{key: {field: value, ...}}`` — the Jira working set
            recently fetched.
        quarantine_set: Optional set of targets whose mutations must be
            suppressed. Every emit point routes through :func:`_emit`,
            which drops any mutation whose ``target`` is in this set. When
            ``None`` (the default), no suppression is performed.
        seed_mutations: Optional list of pre-built Mutations to prepend to
            the result. Used by ``invariants.check_dual_identity_complete``
            (story 7a75) to inject repair/inbound mutations that the differ
            itself cannot derive from local/jira state alone. Seed
            mutations are NOT filtered through ``quarantine_set``.

    Returns:
        A list of ``Mutation`` objects. Seed mutations (if any) appear
        first, followed by differ-emitted mutations sorted by ``target``
        for determinism. Each Mutation carries a non-empty provenance
        Mapping.

    Semantics:
        - Key in ``local_state`` only AND its ``dso_local_id`` is not
          already bound in ``jira_state`` → outbound create.
        - Key in ``local_state`` only but its ``dso_local_id`` IS already
          bound in ``jira_state`` → skipped (already mirrored).
        - Key in ``jira_state`` only → inbound create.
        - Key in both → field-by-field diff (excluding ``EXCLUDED_FIELDS``);
          if any non-excluded field differs, emit an outbound update whose
          payload contains only the resolved changed fields.
        - A create whose only fields are in ``EXCLUDED_FIELDS`` is
          suppressed (no information would survive the field filter).

    This function is pure: no I/O, no time, no logging, no globals.
    """
    if local_state is None:
        local_state = {}
    if jira_state is None:
        jira_state = {}

    config = _load_config()
    conflict_resolver = _load_conflict_resolver()
    mutation_mod = _load_mutation()
    Mutation = mutation_mod.Mutation
    MutationAction = mutation_mod.MutationAction
    MutationDirection = mutation_mod.MutationDirection

    excluded = set(config.EXCLUDED_FIELDS)

    # Build the set of dso_local_ids already bound in the Jira working set.
    # An outbound create for a local ticket whose dso_local_id is already
    # bound in Jira would re-create an already-mirrored issue (dd-4 AC).
    bound_local_ids: set[str] = set()
    # Reverse map: dso_local_id -> jira_key, so we can detect dangling
    # references where the Jira side claims a binding to a local ticket
    # that no longer exists locally (dd-5).
    jira_local_id_to_key: dict[str, str] = {}
    for jira_key, jira_entry in jira_state.items():
        if isinstance(jira_entry, dict):
            cand = jira_entry.get("dso_local_id")
            if cand:
                bound_local_ids.add(str(cand))
                jira_local_id_to_key.setdefault(str(cand), jira_key)

    # Build a map: dso_local_id -> [local_key, ...] from local_state, to
    # detect duplicate dso_local_id collisions across local tickets (dd-5).
    local_id_to_keys: dict[str, list[str]] = {}
    for local_key, local_entry in local_state.items():
        if isinstance(local_entry, dict):
            cand = local_entry.get("dso_local_id")
            if cand:
                local_id_to_keys.setdefault(str(cand), []).append(local_key)
    # The set of local dso_local_ids that have a collision (>1 owners).
    duplicate_local_ids: set[str] = {
        lid for lid, keys in local_id_to_keys.items() if len(keys) > 1
    }
    # The set of local dso_local_ids that are present in local_state at all,
    # used to short-circuit dangling-jira-ref detection.
    local_dso_ids: set[str] = set(local_id_to_keys.keys())

    # Seed mutations (if any) are prepended to the result list before the
    # differ walks local/jira state. They are NOT filtered through
    # quarantine_set — the caller (e.g. invariants.check_dual_identity_complete)
    # has authority over what it injects.
    mutations: list[Any] = list(seed_mutations) if seed_mutations else []
    all_keys = set(local_state) | set(jira_state)

    for key in sorted(all_keys):
        in_local = key in local_state
        in_jira = key in jira_state

        if in_local and not in_jira:
            local_fields = local_state[key] or {}
            local_id_val = (
                local_fields.get("dso_local_id")
                if isinstance(local_fields, dict)
                else None
            )
            local_id_str = str(local_id_val) if local_id_val else None

            # dd-5: duplicate dso_local_id collision across local tickets —
            # surface each colliding owner as an (inbound, conflict) Mutation
            # so the human or downstream tooling can disambiguate. Take
            # precedence over the standard outbound-create path because the
            # underlying state is unbindable as-is.
            if local_id_str and local_id_str in duplicate_local_ids:
                colliding = sorted(local_id_to_keys[local_id_str])
                _emit(
                    Mutation(
                        direction=MutationDirection.inbound,
                        action=MutationAction.conflict,
                        target=key,
                        payload={},
                        provenance={
                            "source": "differ",
                            "reason": "duplicate_local_id",
                            "local_id": local_id_str,
                            "colliding_keys": colliding,
                        },
                    ),
                    quarantine_set=quarantine_set,
                    mutations_out=mutations,
                )
                continue

            if local_id_val and str(local_id_val) in bound_local_ids:
                # Already mirrored in Jira under a different key — do not
                # emit a redundant outbound create. (dd-4)
                continue

            # dd-5: ambiguous local binding — local ticket carries a
            # dso_local_id that matches the KEY of an unrelated Jira issue
            # (an issue that exists in jira_state but does NOT carry a
            # back-pointer dso_local_id binding). This suggests a possibly
            # stale or conflated binding: the local_id may once have referred
            # to that Jira issue, but the Jira side no longer agrees. Emit
            # (outbound, probe) so the applier can disambiguate before
            # blindly creating a duplicate Jira issue.
            #
            # Design choice: a bare unbound_local with dso_local_id and no
            # jira-side signal is treated as a normal outbound create
            # (preserving existing test_differ.py semantics) — the ambiguity
            # signal is the presence of a jira_state entry under the same
            # key as the local_id, without a reciprocal binding.
            if local_id_str and local_id_str in jira_state:
                jira_sibling = jira_state.get(local_id_str) or {}
                sibling_local_id = (
                    jira_sibling.get("dso_local_id")
                    if isinstance(jira_sibling, dict)
                    else None
                )
                if not sibling_local_id:
                    _emit(
                        Mutation(
                            direction=MutationDirection.outbound,
                            action=MutationAction.probe,
                            target=key,
                            payload={},
                            provenance={
                                "source": "differ",
                                "reason": "ambiguous_local_binding",
                                "local_id": local_id_str,
                                "jira_sibling_key": local_id_str,
                            },
                        ),
                        quarantine_set=quarantine_set,
                        mutations_out=mutations,
                    )
                    continue

            payload = {
                f: v
                for f, v in local_fields.items()
                if f not in excluded
            }
            if not payload:
                # Only excluded fields → no useful create payload.
                continue
            _emit(
                Mutation(
                    direction=MutationDirection.outbound,
                    action=MutationAction.create,
                    target=key,
                    payload=payload,
                    provenance=_derive_provenance(
                        target=key,
                        primary_fields=local_fields,
                        fallback_fields=None,
                        reason="unbound_local",
                    ),
                ),
                quarantine_set=quarantine_set,
                mutations_out=mutations,
            )
        elif in_jira and not in_local:
            jira_fields = jira_state[key] or {}
            jira_local_id = (
                jira_fields.get("dso_local_id")
                if isinstance(jira_fields, dict)
                else None
            )
            jira_local_id_str = str(jira_local_id) if jira_local_id else None

            # dd-5: dangling jira ref — the Jira issue claims a binding to a
            # dso_local_id that has no matching local ticket. Surface as
            # (inbound, conflict) so the human can decide whether to recreate
            # the local ticket, clear the Jira-side binding, or close the
            # Jira issue. Never silently drop.
            if jira_local_id_str and jira_local_id_str not in local_dso_ids:
                _emit(
                    Mutation(
                        direction=MutationDirection.inbound,
                        action=MutationAction.conflict,
                        target=key,
                        payload={
                            "jira_field_snapshot": dict(jira_fields),
                        },
                        provenance={
                            "source": "differ",
                            "reason": "dangling_jira_local_id",
                            "dangling_local_id": jira_local_id_str,
                        },
                    ),
                    quarantine_set=quarantine_set,
                    mutations_out=mutations,
                )
                continue

            payload = {
                f: v
                for f, v in jira_fields.items()
                if f not in excluded
            }
            # An inbound create with an empty payload is still meaningful
            # (it announces a new Jira-side issue) — keep the Mutation even
            # if every field is excluded, because the target itself is the
            # signal.
            _emit(
                Mutation(
                    direction=MutationDirection.inbound,
                    action=MutationAction.create,
                    target=key,
                    payload=payload,
                    provenance=_derive_provenance(
                        target=key,
                        primary_fields=jira_fields,
                        fallback_fields=None,
                        reason="jira_new",
                    ),
                ),
                quarantine_set=quarantine_set,
                mutations_out=mutations,
            )
        else:
            # Present in both — diff non-excluded fields.
            local_fields = local_state[key] or {}
            jira_fields = jira_state[key] or {}
            changed: dict[str, Any] = {}
            for field in set(local_fields) | set(jira_fields):
                if field in excluded:
                    continue
                local_val = local_fields.get(field)
                jira_val = jira_fields.get(field)
                if local_val != jira_val:
                    if field in conflict_resolver.FIELD_CLASSES:
                        changed[field] = conflict_resolver.resolve_field(
                            field, local_val, jira_val, provenance_record=None
                        )
                    else:
                        changed[field] = local_val
            if changed:
                _emit(
                    Mutation(
                        direction=MutationDirection.outbound,
                        action=MutationAction.update,
                        target=key,
                        payload=changed,
                        provenance=_derive_provenance(
                            target=key,
                            primary_fields=jira_fields,
                            fallback_fields=local_fields,
                            reason="field_drift",
                        ),
                    ),
                    quarantine_set=quarantine_set,
                    mutations_out=mutations,
                )

    return mutations
