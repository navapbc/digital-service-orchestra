"""Conflict resolver for dso_reconciler.

Provides a FIELD_CLASSES registry and three resolution strategies:
  - resolve_state: local always wins (for deterministic single-value fields)
  - resolve_additive: merge content (lists union-ordered, strings concat, None-safe)
  - resolve_set_valued: union of both sets

resolve_field dispatches to the correct strategy based on FIELD_CLASSES.
"""

from __future__ import annotations

from typing import Any, Optional

# ---------------------------------------------------------------------------
# Field class registry
# ---------------------------------------------------------------------------

FIELD_CLASSES: dict[str, str] = {
    "status": "state",
    "assignee": "state",
    "priority": "state",
    "description": "additive",
    "comments": "additive",
    "labels": "set",
    "watchers": "set",
    "links": "set",
}


# ---------------------------------------------------------------------------
# Resolution strategies
# ---------------------------------------------------------------------------


def resolve_state(local_val: Any, remote_val: Any) -> Any:
    """Local always wins for state fields."""
    return local_val


def resolve_additive(local_val: Any, remote_val: Any) -> Any:
    """Merge additive fields.

    - Both lists  → union ordered (preserve order, no duplicates).
    - Both strings → append remote if it adds new content.
    - One or both None → return whichever is non-None (local preferred).
    """
    # Both lists: union ordered, local first
    if isinstance(local_val, list) and isinstance(remote_val, list):
        seen: set[str] = set()
        result: list[Any] = []
        for item in local_val + remote_val:
            key = str(item)
            if key not in seen:
                seen.add(key)
                result.append(item)
        return result

    # Both strings: append remote only when it contributes new content
    if isinstance(local_val, str) and isinstance(remote_val, str):
        if remote_val and remote_val not in local_val:
            return (local_val + "\n" + remote_val) if local_val else remote_val
        return local_val

    # One or both are None — return whichever is non-None (local first)
    return local_val if local_val is not None else remote_val


_PROVENANCE_CAP = 50


def resolve_set_valued(
    local_set: Any,
    remote_set: Any,
    provenance_record: Optional[Any],
) -> list[Any]:
    """Union of both sets; updates provenance_record with a FIFO cap of 50."""
    seen: set[Any] = set()
    merged: list[Any] = []
    local_list = list(local_set) if local_set else []
    remote_list = list(remote_set) if remote_set else []
    for item in local_list + remote_list:
        if item not in seen:
            merged.append(item)
            seen.add(item)

    if provenance_record is not None and isinstance(provenance_record, list):
        for item in merged:
            if item not in provenance_record:
                if len(provenance_record) >= _PROVENANCE_CAP:
                    provenance_record.pop(0)  # FIFO eviction: remove oldest
                provenance_record.append(item)

    return merged


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------


def resolve_field(
    field_name: str,
    local_val: Any,
    remote_val: Any,
    provenance_record: Optional[Any] = None,
) -> Any:
    """Dispatch to the correct resolver based on FIELD_CLASSES.

    Unknown field names default to resolve_state (local wins).
    """
    field_class = FIELD_CLASSES.get(field_name, "state")
    if field_class == "state":
        return resolve_state(local_val, remote_val)
    if field_class == "additive":
        return resolve_additive(local_val, remote_val)
    if field_class == "set":
        return resolve_set_valued(local_val, remote_val, provenance_record)
    # Fallback (should not be reached with current registry values)
    return resolve_state(local_val, remote_val)
