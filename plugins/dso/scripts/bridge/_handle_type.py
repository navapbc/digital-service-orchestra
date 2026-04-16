"""Type alert handling for the inbound bridge.

Checks Jira issue type mapping and writes BRIDGE_ALERT events for
unmapped type values. Returns whether the issue should be excluded
from CREATE event generation.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any


def handle_type_check(
    issue: dict[str, Any],
    *,
    tickets_root: Path,
    bridge_env_id: str,
    type_mapping: dict[str, str],
    unmapped_type_keys: set[str],
    map_type_fn: Any,
    write_bridge_alert_fn: Any,
) -> bool:
    """Check Jira issue type mapping and write BRIDGE_ALERT if unmapped.

    When the Jira issue type has no mapping, writes a BRIDGE_ALERT event,
    adds the Jira key to unmapped_type_keys, and returns True to signal
    the caller to skip further processing for this issue.

    Args:
        issue: Normalized Jira issue dict.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        type_mapping: Jira type name → local type string mapping.
        unmapped_type_keys: Mutable set to track unmapped Jira keys.
        map_type_fn: Callable matching map_type signature.
        write_bridge_alert_fn: Callable matching write_bridge_alert signature.

    Returns:
        True if the issue should be skipped (unmapped type), False otherwise.
    """
    fields = issue.get("fields", {})

    jira_type = (
        fields.get("issuetype", {}).get("name", "")
        if isinstance(fields.get("issuetype"), dict)
        else ""
    )

    if not jira_type:
        return False

    if map_type_fn(jira_type, mapping=type_mapping) is None:
        local_id = f"jira-{issue.get('key', 'unknown').lower()}"
        write_bridge_alert_fn(
            ticket_id=local_id,
            reason=f"Unknown type value: '{jira_type}'",
            tickets_root=tickets_root,
            bridge_env_id=bridge_env_id,
        )
        # Skip creating a local ticket for unclassifiable types (2b6a-0a37).
        if issue.get("key"):
            unmapped_type_keys.add(issue["key"])
        return True

    return False
