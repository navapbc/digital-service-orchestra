"""Outbound differ for bidirectional Jira sync.

Compares local ticket state against the Jira working-set snapshot and emits
a list of OutboundMutation objects describing changes to push from local to
Jira. Uses a BindingStore (from PR #401) to map local ticket IDs to Jira keys.

Local is the source of truth. Unbound local tickets emit "create" mutations;
bound tickets whose fields diverge from Jira emit "update" mutations with
only the changed fields.

This module is pure: no I/O, no time/random, no logging, no globals.

Dependency: BindingStore interface (PR #401). This module codes against the
interface — get_jira_key(local_id) -> str|None, is_bound(local_id) -> bool —
and does not import the concrete class.
"""

from __future__ import annotations

from dataclasses import dataclass, field as dataclass_field
from typing import Any, Protocol, runtime_checkable


# ---------------------------------------------------------------------------
# BindingStore protocol — codes against PR #401's interface
# ---------------------------------------------------------------------------


@runtime_checkable
class BindingStoreProtocol(Protocol):
    """Minimal interface for the binding store (PR #401)."""

    def get_jira_key(self, local_id: str) -> str | None: ...
    def is_bound(self, local_id: str) -> bool: ...


# ---------------------------------------------------------------------------
# OutboundMutation dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OutboundMutation:
    """A single outbound change to push to Jira."""

    local_id: str
    jira_key: str | None  # None for create (not yet assigned)
    action: str  # "create" | "update" | "delete"
    fields: dict[str, Any]  # changed fields only for update; all fields for create
    comments: list[dict[str, Any]] = dataclass_field(default_factory=list)
    labels: list[dict[str, Any]] = dataclass_field(default_factory=list)
    links: list[dict[str, Any]] = dataclass_field(default_factory=list)


# ---------------------------------------------------------------------------
# Field mapping constants
# ---------------------------------------------------------------------------

_LOCAL_TO_JIRA_TYPE: dict[str, str] = {
    "bug": "Bug",
    "story": "Story",
    "task": "Task",
    "epic": "Epic",
}

_LOCAL_TO_JIRA_PRIORITY: dict[int, str] = {
    0: "Highest",
    1: "High",
    2: "Medium",
    3: "Low",
    4: "Lowest",
}

_LOCAL_TO_JIRA_STATUS: dict[str, str] = {
    "open": "To Do",
    "in_progress": "In Progress",
    "blocked": "Blocked",
    "closed": "Done",
    "cancelled": "Cancelled",
    "deleted": "Done",
}


# ---------------------------------------------------------------------------
# Field mapping helpers
# ---------------------------------------------------------------------------


def _map_local_to_jira_fields(ticket: dict[str, Any]) -> dict[str, Any]:
    """Map local ticket fields to Jira field names/values.

    Use ``.get(key) or default`` (not ``.get(key, default)``) for string
    fields so an explicit ``None`` value normalises to the empty-string
    default. ``.get(key, default)`` only falls back when the key is
    MISSING — if the key exists with value ``None`` (e.g. unassigned
    tickets where the ticket reducer initialises ``assignee: None``),
    .get returns None, not the default. None then propagates through
    ``_diff_fields`` and becomes the literal string ``"None"`` after
    str() conversion at the ACLI boundary, causing ACLI to reject the
    edit with exit 1.
    """
    return {
        "summary": ticket.get("title") or "",
        "description": ticket.get("description") or "",
        "issuetype": _LOCAL_TO_JIRA_TYPE.get(ticket.get("ticket_type", "task"), "Task"),
        "priority": _LOCAL_TO_JIRA_PRIORITY.get(ticket.get("priority", 2), "Medium"),
        "status": _LOCAL_TO_JIRA_STATUS.get(ticket.get("status", "open"), "To Do"),
        "assignee": ticket.get("assignee") or "",
    }


def _extract_jira_field(jira_fields: dict[str, Any], field: str) -> Any:
    """Extract a Jira field value, handling nested structures.

    Jira API returns some fields as nested objects (e.g. priority.name,
    issuetype.name, status.name, assignee.displayName). This helper
    normalises to the string value the outbound differ uses for comparison.
    """
    raw = jira_fields.get(field)
    if raw is None:
        return ""
    if isinstance(raw, dict):
        # Jira nested objects: {name: ..., id: ...}
        return raw.get("name", raw.get("displayName", ""))
    return raw


def _diff_fields(ticket: dict[str, Any], jira_fields: dict[str, Any]) -> dict[str, Any]:
    """Compare local ticket to Jira fields. Return only changed fields.

    Uses local-wins: if local differs, push outbound regardless of Jira state.
    """
    local_mapped = _map_local_to_jira_fields(ticket)
    changed: dict[str, Any] = {}
    for field_name, local_val in local_mapped.items():
        jira_val = _extract_jira_field(jira_fields, field_name)
        if local_val != jira_val:
            changed[field_name] = local_val
    return changed


# ---------------------------------------------------------------------------
# Comment diff
# ---------------------------------------------------------------------------


def _map_comments_for_create(ticket: dict[str, Any]) -> list[dict[str, Any]]:
    """Map all local comments to outbound create mutations."""
    comments = ticket.get("comments", [])
    return [{"action": "add", "body": c.get("body", "")} for c in comments]


def _diff_comments(
    ticket: dict[str, Any],
    jira_key: str,
    jira_snapshot: dict[str, Any],
) -> list[dict[str, Any]]:
    """Compare local comments to Jira comments. Return mutations for new comments.

    Simple strategy: detect local comments not yet mirrored to Jira by
    comparing comment bodies. This is a best-effort approach; PR #402
    (ADF walker + comment binding) will provide exact comment ID binding.
    """
    local_comments = ticket.get("comments", [])
    jira_issue = jira_snapshot.get(jira_key, {})
    jira_comments = jira_issue.get("comments", [])

    jira_bodies: set[str] = set()
    for c in jira_comments:
        body = c.get("body", "") if isinstance(c, dict) else str(c)
        jira_bodies.add(body)

    mutations: list[dict[str, Any]] = []
    for c in local_comments:
        body = c.get("body", "") if isinstance(c, dict) else str(c)
        if body and body not in jira_bodies:
            mutations.append({"action": "add", "body": body})
    return mutations


# ---------------------------------------------------------------------------
# Label diff
# ---------------------------------------------------------------------------

_EXCLUDED_PREFIXES: tuple[str, ...] = ("dso-id-", "imported:")


def _diff_labels(
    ticket: dict[str, Any], jira_fields: dict[str, Any]
) -> list[dict[str, Any]]:
    """Compare local tags to Jira labels. Exclude bridge-internal labels."""
    local_tags: set[str] = set(
        t
        for t in ticket.get("tags", [])
        if not any(t.startswith(p) for p in _EXCLUDED_PREFIXES)
    )
    jira_labels: set[str] = set(
        label
        for label in (jira_fields.get("labels") or [])
        if not any(label.startswith(p) for p in _EXCLUDED_PREFIXES)
    )

    mutations: list[dict[str, Any]] = []
    for label in sorted(local_tags - jira_labels):
        mutations.append({"action": "add", "label": label})
    for label in sorted(jira_labels - local_tags):
        mutations.append({"action": "remove", "label": label})
    return mutations


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def compute_outbound_mutations(
    local_tickets: list[dict[str, Any]],
    jira_snapshot: dict[str, Any],
    binding_store: BindingStoreProtocol,
    excluded_statuses: set[str] | None = None,
) -> list[OutboundMutation]:
    """Diff local tickets against Jira snapshot and return outbound mutations.

    Args:
        local_tickets: List of local ticket dicts. Each has: ticket_id, title,
            description, status, priority, ticket_type, assignee, tags, comments,
            deps.
        jira_snapshot: Dict of {jira_key: {fields...}} from the fetcher.
        binding_store: A BindingStore instance providing get_jira_key(local_id),
            is_bound(local_id).
        excluded_statuses: Statuses to skip (default: {"archived", "deleted"}).

    Returns:
        List of OutboundMutation objects describing changes to push to Jira.
    """
    if excluded_statuses is None:
        excluded_statuses = {"archived", "deleted"}

    mutations: list[OutboundMutation] = []

    for ticket in local_tickets:
        status = ticket.get("status", "")
        if status in excluded_statuses:
            continue

        local_id = ticket["ticket_id"]
        jira_key = binding_store.get_jira_key(local_id)

        if jira_key is None:
            # Unbound -> outbound create
            mutations.append(
                OutboundMutation(
                    local_id=local_id,
                    jira_key=None,
                    action="create",
                    fields=_map_local_to_jira_fields(ticket),
                    comments=_map_comments_for_create(ticket),
                    labels=[
                        {"action": "add", "label": t}
                        for t in sorted(ticket.get("tags", []))
                        if not any(t.startswith(p) for p in _EXCLUDED_PREFIXES)
                    ],
                    links=[],  # links resolved after all creates
                )
            )
        else:
            # Bound -> compare fields, emit update if different
            jira_fields = jira_snapshot.get(jira_key, {})
            changed = _diff_fields(ticket, jira_fields)
            comment_mutations = _diff_comments(ticket, jira_key, jira_snapshot)
            label_mutations = _diff_labels(ticket, jira_fields)

            if changed or comment_mutations or label_mutations:
                mutations.append(
                    OutboundMutation(
                        local_id=local_id,
                        jira_key=jira_key,
                        action="update",
                        fields=changed,
                        comments=comment_mutations,
                        labels=label_mutations,
                        links=[],
                    )
                )

    return mutations
