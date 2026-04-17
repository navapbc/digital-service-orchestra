"""Destructive change guard for the inbound bridge.

Checks whether an inbound Jira issue would overwrite existing local data
destructively (empty-over-non-empty description, relationship removal,
or type downgrade). When a destructive change is detected, writes a
BRIDGE_ALERT event and signals the caller to skip further processing.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any


if TYPE_CHECKING:
    pass


def check_destructive_guard(
    issue: dict[str, Any],
    *,
    tickets_root: Path,
    bridge_env_id: str,
    type_mapping: dict[str, str],
    is_destructive_change_fn: Any,
    map_type_fn: Any,
    write_bridge_alert_fn: Any,
) -> bool:
    """Check if the inbound issue would cause a destructive change.

    Reads the latest SYNC event for the ticket to get the existing local
    state, then compares against the inbound Jira fields. When destructive,
    writes a BRIDGE_ALERT and returns True (caller should skip this issue).

    Args:
        issue: Normalized Jira issue dict.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        type_mapping: Jira type name → local type string mapping.
        is_destructive_change_fn: Callable matching is_destructive_change signature.
        map_type_fn: Callable matching map_type signature.
        write_bridge_alert_fn: Callable matching write_bridge_alert signature.

    Returns:
        True if the issue should be skipped (destructive), False otherwise.
    """
    jira_key = issue.get("key", "")
    if not jira_key:
        return False

    local_id = f"jira-{jira_key.lower()}"
    ticket_dir = tickets_root / local_id
    if not ticket_dir.is_dir():
        return False

    # Read latest SYNC event to get existing local state
    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    if not sync_files:
        return False

    try:
        sync_data = json.loads(sync_files[-1].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False

    existing_state = sync_data.get("data", {})
    fields = issue.get("fields", {})

    # Build inbound state dict for comparison
    jira_issuelinks = fields.get("issuelinks", [])
    inbound_links: list[str] = []
    for jira_link in jira_issuelinks:
        target_key = ""
        if "outwardIssue" in jira_link:
            target_key = jira_link["outwardIssue"].get("key", "")
        elif "inwardIssue" in jira_link:
            target_key = jira_link["inwardIssue"].get("key", "")
        if target_key:
            inbound_links.append(f"jira-{target_key.lower()}")

    inbound_state: dict[str, Any] = {
        "description": fields.get("description", ""),
        "links": inbound_links,
        "type": existing_state.get("type", ""),
    }

    # Map inbound type if available
    jira_itype = (
        fields.get("issuetype", {}).get("name", "")
        if isinstance(fields.get("issuetype"), dict)
        else ""
    )
    if jira_itype:
        mapped_type = map_type_fn(jira_itype, mapping=type_mapping)
        if mapped_type:
            inbound_state["type"] = mapped_type

    if is_destructive_change_fn(existing_state, inbound_state):
        reason = (
            f"Destructive change blocked for {local_id}: "
            "inbound update would overwrite existing description/links/type"
        )
        logging.warning(reason)
        write_bridge_alert_fn(
            ticket_id=local_id,
            reason=reason,
            tickets_root=tickets_root,
            bridge_env_id=bridge_env_id,
        )
        return True

    return False
