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
    ticket_reducer: Any = None,
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
        is_outward = False
        if "outwardIssue" in link and link["outwardIssue"]:
            target_key = link["outwardIssue"].get("key", "")
            is_outward = True
        elif "inwardIssue" in link and link["inwardIssue"]:
            target_key = link["inwardIssue"].get("key", "")
            is_outward = False

        if not (link_type and target_key):
            continue

        if link_type == "Relates":
            # Lossy supersedes precedence (5492-58d7 part 4/4): Jira lacks a
            # native "supersedes" link type, so outbound writes supersedes as
            # "Relates". On inbound, if local state already has a `supersedes`
            # link to the same target, local wins (we do NOT downgrade the
            # local supersedes by emitting a relates_to). Otherwise emit the
            # standard bidirectional relates_to pair.
            target_local_id = f"jira-{target_key.lower()}"
            if _local_has_supersedes_to(ticket_dir, target_local_id, ticket_reducer):
                continue
            _write_bidirectional_relates_link(
                source_local_id=local_id,
                target_key=target_key,
                ticket_dir=ticket_dir,
                tickets_root=tickets_root,
                bridge_env_id=bridge_env_id,
            )
        elif link_type == "Blocks":
            # Direction-aware mapping:
            #   outwardIssue → this issue blocks target_key  (relation=blocks)
            #   inwardIssue  → target_key blocks this issue  (relation=depends_on)
            # Reciprocal event uses the inverse relation so both ends agree.
            if is_outward:
                source_relation = "blocks"
                target_relation = "depends_on"
            else:
                source_relation = "depends_on"
                target_relation = "blocks"
            _write_bidirectional_link(
                source_local_id=local_id,
                target_key=target_key,
                source_relation=source_relation,
                target_relation=target_relation,
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


def _local_has_supersedes_to(
    ticket_dir: Path, target_local_id: str, ticket_reducer: Any
) -> bool:
    """Return True iff local state has a supersedes link to target_local_id.

    Used by the lossy supersedes/Relates precedence rule: when Jira sends a
    Relates link for which local has already recorded a supersedes link, we
    do not overwrite the local supersedes by emitting a competing relates_to.

    None semantics (intentional, fail-open): when ticket_reducer is None or
    ticket_dir does not exist, this returns False so the caller falls through
    to the standard relates_to write path. Production callers in process_inbound
    always supply ticket_reducer; the None-tolerant branch exists for unit tests
    that exercise non-supersedes Relates paths and for direct set_relationship
    calls outside the inbound pipeline. The downside is that a missing reducer
    silently shadows local supersedes links — an upstream caller bug would
    surface as duplicated relates_to events rather than a hard failure.
    """
    if ticket_reducer is None or not ticket_dir.is_dir():
        return False
    try:
        state = ticket_reducer.reduce_ticket(str(ticket_dir))
    except Exception:
        return False
    if not isinstance(state, dict):
        return False
    deps = state.get("deps") or []
    if not isinstance(deps, list):
        return False
    for dep in deps:
        if not isinstance(dep, dict):
            continue
        if (
            dep.get("relation") == "supersedes"
            and dep.get("target_id") == target_local_id
        ):
            return True
    return False


def _write_bidirectional_relates_link(
    *,
    source_local_id: str,
    target_key: str,
    ticket_dir: Path,
    tickets_root: Path,
    bridge_env_id: str,
) -> None:
    """Write a bidirectional pair of LINK events for a "Relates" link."""
    _write_bidirectional_link(
        source_local_id=source_local_id,
        target_key=target_key,
        source_relation="relates_to",
        target_relation="relates_to",
        ticket_dir=ticket_dir,
        tickets_root=tickets_root,
        bridge_env_id=bridge_env_id,
    )


def _write_bidirectional_link(
    *,
    source_local_id: str,
    target_key: str,
    source_relation: str,
    target_relation: str,
    ticket_dir: Path,
    tickets_root: Path,
    bridge_env_id: str,
) -> None:
    """Write a directional pair of LINK events with separate source/target relations.

    Used for both symmetric relations (relates_to) and asymmetric ones
    (blocks ↔ depends_on). The source ticket records ``source_relation``
    pointing at target; the reciprocal in the target ticket records
    ``target_relation`` pointing back at source.
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
            "relation": source_relation,
        },
    }
    (ticket_dir / filename).write_text(json.dumps(link_event))

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
            "relation": target_relation,
        },
    }
    (target_dir / recip_filename).write_text(json.dumps(recip_link_event))
