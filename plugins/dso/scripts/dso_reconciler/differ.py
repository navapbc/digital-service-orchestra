"""Pure-function snapshot differ for dso_reconciler.

Compares two flat snapshot dicts and emits a list of mutations needed
to transition from the previous state to the next state.

Fields listed in EXCLUDED_FIELDS (from config.py) are ignored during
comparison and never appear in mutation payloads.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


def _load_config():
    config_path = Path(__file__).parent / "config.py"
    spec = importlib.util.spec_from_file_location("dso_reconciler_config", config_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("dso_reconciler_config", mod)
    spec.loader.exec_module(mod)
    return mod


def _load_conflict_resolver():
    resolver_path = Path(__file__).parent / "conflict_resolver.py"
    spec = importlib.util.spec_from_file_location(
        "dso_reconciler_conflict_resolver", resolver_path
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("dso_reconciler_conflict_resolver", mod)
    spec.loader.exec_module(mod)
    return mod


def compute_mutations(
    prev_snapshot: dict[str, dict],
    next_snapshot: dict[str, dict],
) -> list[dict]:
    """Compare two snapshots and return mutations needed.

    Each snapshot is a flat dict: ``{jira_key: {field_name: field_value, ...}}``.

    Returns a list of mutation dicts, each with:
        - ``action``: one of ``"create"``, ``"update"``, ``"delete"``
        - ``key``: the Jira issue key (str)
        - ``fields``: dict of field names → new values (empty for delete)

    Fields in EXCLUDED_FIELDS are silently skipped; they never appear in
    the returned mutations and never cause a mutation to be emitted.

    This function is pure: it performs no I/O and has no side effects.
    """
    config = _load_config()
    conflict_resolver = _load_conflict_resolver()
    excluded = set(config.EXCLUDED_FIELDS)
    mutations: list[dict] = []

    all_keys = set(prev_snapshot) | set(next_snapshot)
    for key in sorted(all_keys):
        if key not in prev_snapshot:
            # New issue: emit a create mutation with all non-excluded fields.
            fields = {
                f: v
                for f, v in next_snapshot[key].items()
                if f not in excluded
            }
            if fields:
                # local_id: for create, no local ticket exists yet — the bridge
                # ASSIGNS one downstream. Use jira_key as the no-op default so
                # JQL dedup ('dso-id:<local_id>') and mapping.json key lookups
                # have a non-empty identifier in the common case.
                # TODO: when the bridge gains a proper local_id allocator, swap
                # this for the allocated UUID. F2: ensure local_id is always set.
                mutations.append(
                    {
                        "action": "create",
                        "key": key,
                        "local_id": _derive_local_id(next_snapshot[key], key),
                        "fields": fields,
                    }
                )
        elif key not in next_snapshot:
            # Deleted issue: emit a delete mutation with no field payload.
            # local_id carried from the prior snapshot so downstream identity-
            # write rollback paths have a non-empty key for the alert directory.
            mutations.append(
                {
                    "action": "delete",
                    "key": key,
                    "local_id": _derive_local_id(prev_snapshot[key], key),
                    "fields": {},
                }
            )
        else:
            # Existing issue: compare field-by-field for updates.
            prev = prev_snapshot[key]
            next_ = next_snapshot[key]
            changed: dict = {}
            for field in set(prev) | set(next_):
                if field in excluded:
                    continue
                local_val = next_.get(field)
                remote_val = prev.get(field)
                if remote_val != local_val:
                    if field in conflict_resolver.FIELD_CLASSES:
                        resolved = conflict_resolver.resolve_field(
                            field, local_val, remote_val, provenance_record=None
                        )
                        changed[field] = resolved
                    else:
                        changed[field] = local_val
            if changed:
                # For update, prefer the previous snapshot's dso_local_id (the
                # canonical local identity already assigned). Fall back to the
                # next snapshot's value, then the jira_key.
                mutations.append(
                    {
                        "action": "update",
                        "key": key,
                        "local_id": _derive_local_id(
                            prev, key, fallback_snapshot=next_
                        ),
                        "fields": changed,
                    }
                )

    return mutations


def _derive_local_id(
    snapshot_fields: dict,
    jira_key: str,
    fallback_snapshot: dict | None = None,
) -> str:
    """Derive a non-empty local_id for a mutation.

    Order: snapshot's ``dso_local_id`` property → fallback snapshot's
    ``dso_local_id`` → jira_key. The jira_key fallback guarantees JQL dedup
    (``labels = "dso-id:<local_id>"``) and mapping.json writes use a non-empty
    key — fixes F2 where empty local_id collapsed dedup and corrupted mapping.
    """
    candidate = snapshot_fields.get("dso_local_id") if isinstance(snapshot_fields, dict) else None
    if candidate:
        return str(candidate)
    if fallback_snapshot and isinstance(fallback_snapshot, dict):
        candidate = fallback_snapshot.get("dso_local_id")
        if candidate:
            return str(candidate)
    return jira_key
