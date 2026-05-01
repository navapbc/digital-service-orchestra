"""Shared SYNC event I/O — used by both inbound and outbound bridge paths.

A SYNC event file binds a local ticket directory to a remote Jira issue.
Both directions (inbound CREATE, outbound CREATE) must be able to write
SYNC markers using the same payload schema, so the writer lives here
rather than in either bridge half.
"""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path


def has_existing_sync(ticket_dir: Path) -> bool:
    """Return True if a SYNC event file already exists in the ticket directory."""
    return any(ticket_dir.glob("*-SYNC.json"))


def write_sync_event(
    ticket_dir: Path,
    jira_key: str,
    local_id: str,
    bridge_env_id: str,
    run_id: str = "",
) -> Path:
    """Write a SYNC event file to the ticket directory and return its path."""
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-SYNC.json"
    payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": local_id,
        "env_id": bridge_env_id,
        "timestamp": ts,
        "run_id": run_id,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload, ensure_ascii=False))
    return path
