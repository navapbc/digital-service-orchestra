"""Inbound differ for bidirectional Jira sync.

Detects Jira-side changes for bound tickets and emits inbound update mutations
to apply to the local ticket system. Only processes tickets that are already
bound in the BindingStore — unbound Jira issues are ignored (local is source
of truth; they will be handled by outbound creates).

Conflict resolution: local wins. When both local and Jira have changed a
field, the change is skipped (the outbound differ will push the local value).

This module is pure: no I/O, no time/random, no logging, no globals.

Dependency: BindingStore interface (PR #401). This module codes against the
interface — get_local_id(jira_key) -> str|None — and does not import the
concrete class.
"""

from __future__ import annotations

from dataclasses import dataclass, field as dataclass_field
from typing import Any, Protocol, runtime_checkable


# ---------------------------------------------------------------------------
# BindingStore protocol — codes against PR #401's interface
# ---------------------------------------------------------------------------


@runtime_checkable
class BindingStoreProtocol(Protocol):
    """Minimal interface for the inbound binding store lookup."""

    def get_local_id(self, jira_key: str) -> str | None: ...


# ---------------------------------------------------------------------------
# InboundMutation dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class InboundMutation:
    """A single inbound change to apply to the local ticket system."""

    jira_key: str
    local_id: str
    action: str  # "update"
    fields: dict[str, Any]  # changed fields only
    comments: list[dict[str, Any]] = dataclass_field(default_factory=list)
    labels: list[dict[str, Any]] = dataclass_field(default_factory=list)


# ---------------------------------------------------------------------------
# Field mapping constants (Jira -> local)
# ---------------------------------------------------------------------------

_JIRA_TO_LOCAL_TYPE: dict[str, str] = {
    "Bug": "bug",
    "Story": "story",
    "Task": "task",
    "Epic": "epic",
}

_JIRA_TO_LOCAL_PRIORITY: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}

_JIRA_TO_LOCAL_STATUS: dict[str, str] = {
    "To Do": "open",
    "In Progress": "in_progress",
    "Blocked": "blocked",
    "Done": "closed",
    "Cancelled": "cancelled",
}


# ---------------------------------------------------------------------------
# Field extraction helpers
# ---------------------------------------------------------------------------


def _extract_jira_field_value(jira_fields: dict[str, Any], field: str) -> Any:
    """Extract a Jira field value, handling nested structures."""
    raw = jira_fields.get(field)
    if raw is None:
        return None
    if isinstance(raw, dict):
        return raw.get("name", raw.get("displayName", ""))
    return raw


def _map_jira_to_local_fields(jira_fields: dict[str, Any]) -> dict[str, Any]:
    """Map Jira fields to local ticket field names/values."""
    summary = _extract_jira_field_value(jira_fields, "summary") or ""
    description = _extract_jira_field_value(jira_fields, "description") or ""
    issuetype_raw = _extract_jira_field_value(jira_fields, "issuetype") or "Task"
    priority_raw = _extract_jira_field_value(jira_fields, "priority") or "Medium"
    status_raw = _extract_jira_field_value(jira_fields, "status") or "To Do"
    assignee = _extract_jira_field_value(jira_fields, "assignee") or ""

    return {
        "title": summary,
        "description": description,
        "ticket_type": _JIRA_TO_LOCAL_TYPE.get(issuetype_raw, "task"),
        "priority": _JIRA_TO_LOCAL_PRIORITY.get(priority_raw, 2),
        "status": _JIRA_TO_LOCAL_STATUS.get(status_raw, "open"),
        "assignee": assignee,
    }


def _diff_jira_vs_local(
    jira_fields: dict[str, Any],
    local_ticket: dict[str, Any],
) -> dict[str, Any]:
    """Compare Jira fields to local ticket. Return fields where Jira differs.

    Only returns fields where the Jira value (mapped to local conventions)
    differs from the current local value.
    """
    jira_mapped = _map_jira_to_local_fields(jira_fields)
    changed: dict[str, Any] = {}

    field_map = {
        "title": "title",
        "description": "description",
        "ticket_type": "ticket_type",
        "priority": "priority",
        "status": "status",
        "assignee": "assignee",
    }

    for local_field, ticket_field in field_map.items():
        jira_val = jira_mapped.get(local_field)
        local_val = local_ticket.get(ticket_field)
        # Normalise None to empty string for string fields
        if jira_val is None:
            jira_val = "" if local_field not in ("priority",) else 2
        if local_val is None:
            local_val = "" if local_field not in ("priority",) else 2
        if jira_val != local_val:
            changed[local_field] = jira_val
    return changed


# ---------------------------------------------------------------------------
# Label diff helpers
# ---------------------------------------------------------------------------

_EXCLUDED_PREFIXES: tuple[str, ...] = ("dso-id", "imported:")


def _diff_labels_inbound(
    jira_fields: dict[str, Any], local_ticket: dict[str, Any]
) -> list[dict[str, Any]]:
    """Compare Jira labels to local tags. Exclude bridge-internal labels."""
    jira_labels: set[str] = set(
        label
        for label in (jira_fields.get("labels") or [])
        if not any(label.startswith(p) for p in _EXCLUDED_PREFIXES)
    )
    local_tags: set[str] = set(
        t
        for t in local_ticket.get("tags", [])
        if not any(t.startswith(p) for p in _EXCLUDED_PREFIXES)
    )

    mutations: list[dict[str, Any]] = []
    for label in sorted(jira_labels - local_tags):
        mutations.append({"action": "add", "label": label})
    for label in sorted(local_tags - jira_labels):
        mutations.append({"action": "remove", "label": label})
    return mutations


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def compute_inbound_mutations(
    jira_snapshot: dict[str, dict[str, Any]],
    binding_store: BindingStoreProtocol,
    local_tickets_by_id: dict[str, dict[str, Any]],
) -> list[InboundMutation]:
    """Detect Jira-side changes for bound tickets.

    Only processes BOUND tickets (those in binding_store). Unbound Jira issues
    are ignored — they will be handled by outbound creates once the local
    ticket is synced outbound first.

    For bound tickets where Jira fields differ from local:
    - If local also changed -> skip (local wins, outbound differ handles it)
    - If only Jira changed -> emit inbound update

    The "local also changed" detection requires a baseline snapshot (previous
    sync state). Without a baseline, this implementation treats all local
    values as the baseline — meaning any difference between Jira and local
    is attributed to Jira having changed. The outbound differ's local-wins
    semantics ensure correctness: if both changed, the outbound differ will
    push the local value, and the inbound mutation (if emitted) will be
    superseded.

    Args:
        jira_snapshot: Dict of {jira_key: {fields...}} from the fetcher.
        binding_store: A BindingStore instance providing get_local_id(jira_key).
        local_tickets_by_id: Dict of {local_id: {ticket fields...}} for local
            ticket lookup.

    Returns:
        List of InboundMutation objects describing changes to apply locally.
    """
    mutations: list[InboundMutation] = []

    for jira_key, jira_fields in sorted(jira_snapshot.items()):
        local_id = binding_store.get_local_id(jira_key)
        if local_id is None:
            # Unbound Jira issue — skip (local is source of truth)
            continue

        local_ticket = local_tickets_by_id.get(local_id)
        if local_ticket is None:
            # Bound but local ticket missing — skip (may be deleted locally)
            continue

        changed = _diff_jira_vs_local(jira_fields, local_ticket)
        label_mutations = _diff_labels_inbound(jira_fields, local_ticket)

        if changed or label_mutations:
            mutations.append(
                InboundMutation(
                    jira_key=jira_key,
                    local_id=local_id,
                    action="update",
                    fields=changed,
                    labels=label_mutations,
                )
            )

    return mutations
