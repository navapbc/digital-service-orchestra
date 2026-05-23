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
                mutations.append({"action": "create", "key": key, "fields": fields})
        elif key not in next_snapshot:
            # Deleted issue: emit a delete mutation with no field payload.
            mutations.append({"action": "delete", "key": key, "fields": {}})
        else:
            # Existing issue: compare field-by-field for updates.
            prev = prev_snapshot[key]
            next_ = next_snapshot[key]
            changed: dict = {}
            for field in set(prev) | set(next_):
                if field in excluded:
                    continue
                if prev.get(field) != next_.get(field):
                    changed[field] = next_.get(field)
            if changed:
                mutations.append({"action": "update", "key": key, "fields": changed})

    return mutations
