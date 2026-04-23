"""Issue link processing for the inbound bridge.

Handles Jira issuelinks for a single issue:
- "Relates" links → bidirectional local LINK events
- Other link types → push relationship to Jira via acli_client.set_relationship;
  on failure, write a rejection record and BRIDGE_ALERT.
"""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path
from typing import Any


def handle_links(
    issue: dict[str, Any],
    *,
    tickets_root: Path,
    bridge_env_id: str,
    acli_client: Any,
    persist_relationship_rejection_fn: Any,
    write_bridge_alert_fn: Any,
) -> None:
    """Process Jira issuelinks for a single issue.

    For "Relates" link type: writes bidirectional local LINK events in
    the source and target ticket directories.

    For all other link types: calls acli_client.set_relationship(); on
    failure, records the rejection and writes a BRIDGE_ALERT.

    Args:
        issue: Normalized Jira issue dict.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        acli_client: ACLI client object (may have set_relationship method).
        persist_relationship_rejection_fn: Callable matching
            persist_relationship_rejection signature.
        write_bridge_alert_fn: Callable matching write_bridge_alert signature.
    """
    fields = issue.get("fields", {})
    issue_links = fields.get("issuelinks", [])
    if not issue_links:
        return

    jira_key = issue.get("key", "")
    if not jira_key:
        return

    local_id = f"jira-{jira_key.lower()}"
    ticket_dir = tickets_root / local_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    for link in issue_links:
        link_type = link.get("type", {}).get("name", "")
        target_key = ""
        if "outwardIssue" in link:
            target_key = link["outwardIssue"].get("key", "")
        elif "inwardIssue" in link:
            target_key = link["inwardIssue"].get("key", "")

        if not (link_type and target_key):
            continue

        if link_type == "Relates":
            _write_bidirectional_relates_link(
                source_local_id=local_id,
                target_key=target_key,
                ticket_dir=ticket_dir,
                tickets_root=tickets_root,
                bridge_env_id=bridge_env_id,
            )
        elif hasattr(acli_client, "set_relationship"):
            try:
                acli_client.set_relationship(jira_key, target_key, link_type)
            except Exception as rel_exc:
                reason = str(rel_exc)
                persist_relationship_rejection_fn(
                    ticket_id=local_id,
                    ticket_dir=ticket_dir,
                    reason=reason,
                )
                write_bridge_alert_fn(
                    ticket_id=local_id,
                    reason=f"Jira rejected relationship: {reason}",
                    tickets_root=tickets_root,
                    bridge_env_id=bridge_env_id,
                )


def _write_bidirectional_relates_link(
    *,
    source_local_id: str,
    target_key: str,
    ticket_dir: Path,
    tickets_root: Path,
    bridge_env_id: str,
) -> None:
    """Write a bidirectional pair of LINK events for a "Relates" link.

    Writes one LINK event in source ticket dir and one reciprocal LINK
    event in the target ticket dir.
    """
    target_local_id = f"jira-{target_key.lower()}"
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid[:8]}-LINK.json"

    link_event: dict[str, Any] = {
        "event_type": "LINK",
        "ticket_id": source_local_id,
        "timestamp": ts,
        "uuid": event_uuid,
        "env_id": bridge_env_id,
        "data": {
            "source_id": source_local_id,
            "target_id": target_local_id,
            "relation": "relates_to",
        },
    }
    (ticket_dir / filename).write_text(json.dumps(link_event))

    # Reciprocal LINK event in target ticket directory
    target_dir = tickets_root / target_local_id
    target_dir.mkdir(parents=True, exist_ok=True)
    recip_uuid = str(uuid.uuid4())
    recip_filename = f"{ts}-{recip_uuid[:8]}-LINK.json"
    recip_link_event: dict[str, Any] = {
        "event_type": "LINK",
        "ticket_id": target_local_id,
        "timestamp": ts,
        "uuid": recip_uuid,
        "env_id": bridge_env_id,
        "data": {
            "source_id": target_local_id,
            "target_id": source_local_id,
            "relation": "relates_to",
        },
    }
    (target_dir / recip_filename).write_text(json.dumps(recip_link_event))
