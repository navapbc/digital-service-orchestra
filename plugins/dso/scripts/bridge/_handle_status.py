"""Status event handling for the inbound bridge.

Handles two tasks:
1. Writing BRIDGE_ALERT events for unmapped Jira status values.
2. Writing STATUS events when the Jira status differs from the
   current compiled local status.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def handle_status(
    issue: dict[str, Any],
    *,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str,
    status_mapping: dict[str, str],
    map_status_fn: Any,
    write_bridge_alert_fn: Any,
    write_status_event_fn: Any,
) -> None:
    """Process status for a single Jira issue.

    Writes a BRIDGE_ALERT when the Jira status has no mapping, and writes
    a STATUS event when the mapped local status differs from the current
    compiled local status.

    Args:
        issue: Normalized Jira issue dict.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        run_id: Run ID for traceability.
        status_mapping: Jira status name → local status string mapping.
        map_status_fn: Callable matching map_status signature.
        write_bridge_alert_fn: Callable matching write_bridge_alert signature.
        write_status_event_fn: Callable matching write_status_event signature.
    """
    fields = issue.get("fields", {})

    jira_status = (
        fields.get("status", {}).get("name", "")
        if isinstance(fields.get("status"), dict)
        else ""
    )

    if not jira_status:
        return

    # Alert on unmapped status
    if map_status_fn(jira_status, mapping=status_mapping) is None:
        local_id = f"jira-{issue.get('key', 'unknown').lower()}"
        write_bridge_alert_fn(
            ticket_id=local_id,
            reason=f"Unknown status value: '{jira_status}'",
            tickets_root=tickets_root,
            bridge_env_id=bridge_env_id,
        )

    # Write STATUS event if mapped and differs from local compiled status
    mapped_local_status = map_status_fn(jira_status, mapping=status_mapping)
    if mapped_local_status is None:
        return

    jira_key = issue.get("key", "")
    if not jira_key:
        return

    local_id = f"jira-{jira_key.lower()}"
    ticket_dir = tickets_root / local_id
    if not ticket_dir.is_dir():
        return

    # Find the latest STATUS event by reading JSON timestamps
    # (not filename sort) to handle same-second events with random UUIDs.
    status_files = list(ticket_dir.glob("*-STATUS.json"))
    current_local_status = ""
    if status_files:
        best_ts = -1
        for sf in status_files:
            try:
                sf_data = json.loads(sf.read_text(encoding="utf-8"))
                sf_ts = sf_data.get("timestamp", 0)
                if isinstance(sf_ts, (int, float)) and sf_ts > best_ts:
                    best_ts = sf_ts
                    current_local_status = sf_data.get("data", {}).get("status", "")
            except (OSError, json.JSONDecodeError):
                pass

    if mapped_local_status != current_local_status:
        write_status_event_fn(
            ticket_id=local_id,
            status=mapped_local_status,
            ticket_dir=ticket_dir,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )
