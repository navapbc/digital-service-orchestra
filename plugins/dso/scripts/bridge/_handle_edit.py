"""EDIT event generation for the inbound bridge.

Compares Jira field values against the local compiled ticket state and
writes EDIT events for fields that have changed (priority, assignee,
title, description).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

# Jira priority name → local 0-4 integer scale
_JIRA_PRIORITY_TO_LOCAL: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}


def handle_edit(
    issue: dict[str, Any],
    *,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str,
    ticket_reducer: Any,
    write_edit_event_fn: Any,
) -> None:
    """Write EDIT events for changed Jira fields on an existing ticket.

    Compares priority, assignee, title, and description from the Jira issue
    against the local compiled state. Writes a single EDIT event containing
    all changed fields if any differ.

    Empty description safeguard: never overwrites a non-empty local
    description with an empty Jira description.

    Args:
        issue: Normalized Jira issue dict.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        run_id: Run ID for traceability.
        ticket_reducer: Pre-loaded ticket-reducer module (or None to skip).
        write_edit_event_fn: Callable matching write_edit_event signature.
    """
    if ticket_reducer is None:
        return

    jira_key = issue.get("key", "")
    if not jira_key:
        return

    local_id = f"jira-{jira_key.lower()}"
    ticket_dir = tickets_root / local_id
    if not ticket_dir.is_dir():
        return

    # Use reducer to get compiled local state
    try:
        local_state = ticket_reducer.reduce_ticket(str(ticket_dir))
    except Exception:
        return

    if not local_state or not isinstance(local_state, dict):
        return

    fields = issue.get("fields", {})
    edit_fields: dict[str, Any] = {}

    # Priority: map Jira name → local 0-4 integer
    jira_pri_obj = fields.get("priority", {})
    if isinstance(jira_pri_obj, dict):
        pri_name = jira_pri_obj.get("name", "")
        mapped_pri = _JIRA_PRIORITY_TO_LOCAL.get(pri_name)
        if mapped_pri is not None and mapped_pri != local_state.get("priority"):
            edit_fields["priority"] = mapped_pri

    # Assignee: map Jira object → local string
    jira_asn_obj = fields.get("assignee", {})
    if isinstance(jira_asn_obj, dict):
        jira_asn_name = jira_asn_obj.get(
            "displayName", jira_asn_obj.get("emailAddress", "")
        )
        if jira_asn_name and jira_asn_name != local_state.get("assignee"):
            edit_fields["assignee"] = jira_asn_name

    # Title: compare Jira summary → local title
    jira_title = fields.get("summary", "")
    if jira_title and jira_title != local_state.get("title"):
        edit_fields["title"] = jira_title

    # Description: compare Jira description → local description.
    # Empty description safeguard: never overwrite a non-empty local
    # description with an empty Jira description.
    jira_desc = fields.get("description", "")
    if isinstance(jira_desc, str) and jira_desc.strip():
        local_desc = local_state.get("description") or ""
        if jira_desc != local_desc:
            edit_fields["description"] = jira_desc

    # Parent (Epic Link / parent issue): compare Jira parent → local parent_id.
    # Jira parent appears as either fields.parent.key (Cloud) or fields.customfield_10014
    # (legacy Epic Link). When present, translate to the canonical local id format
    # `jira-{key.lower()}` so reducer EDIT processing applies cleanly.
    jira_parent_key: str | None = None
    parent_obj = fields.get("parent")
    if isinstance(parent_obj, dict):
        candidate = parent_obj.get("key", "")
        if isinstance(candidate, str) and candidate.strip():
            jira_parent_key = candidate.strip()
    if not jira_parent_key:
        epic_link = fields.get("customfield_10014")
        if isinstance(epic_link, str) and epic_link.strip():
            jira_parent_key = epic_link.strip()

    if jira_parent_key is not None:
        local_parent_id = f"jira-{jira_parent_key.lower()}"
        if local_parent_id != (local_state.get("parent_id") or ""):
            edit_fields["parent_id"] = local_parent_id

    if edit_fields:
        write_edit_event_fn(
            ticket_id=local_id,
            fields=edit_fields,
            ticket_dir=ticket_dir,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )
