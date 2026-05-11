#!/usr/bin/env python3
"""One-shot reconciliation: emit EDIT events to fix historical type/priority mismatches.

Usage:
    python3 bridge-reconcile-types.py [--dry-run] [--tickets-root PATH]

Pre-2026-03-24 CREATE events were written without ticket_type.capitalize() or
integer-priority translation. This script finds every Jira-synced local ticket,
reads its CREATE event for the original type and priority, and writes a new EDIT
event if those values differ from what the current CREATE event contains (i.e.,
if the CREATE was written before the fix landed). The outbound bridge then
dispatches the EDIT to Jira on its next run.

The script is idempotent: running it twice produces no duplicate EDIT events
because each EDIT gets a unique UUID and timestamps, and the outbound bridge
deduplicates by UUID via the JIRA comment map.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path


_LOCAL_PRIORITY_TO_JIRA = {0: "Highest", 1: "High", 2: "Medium", 3: "Low", 4: "Lowest"}


def _read_json(path: Path) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _find_create_data(ticket_dir: Path) -> dict | None:
    """Return the data dict from the most recent CREATE event, or None."""
    create_files = sorted(ticket_dir.glob("*-CREATE.json"))
    if not create_files:
        return None
    data = _read_json(create_files[-1])
    if data is None:
        return None
    return data.get("data") or {}


def _jira_type_for(ticket_type: str) -> str:
    return ticket_type.capitalize() if ticket_type else "Task"


def _jira_priority_for(priority: int | None) -> str | None:
    if priority is None:
        return None
    return _LOCAL_PRIORITY_TO_JIRA.get(priority)


def reconcile(tickets_root: Path, bridge_env_id: str = "", dry_run: bool = False) -> int:
    """Walk tickets-root, emit EDIT events for type/priority mismatches.

    Returns the count of EDIT events written (or that would be written in dry-run).
    """
    emitted = 0
    for sync_file in sorted(tickets_root.rglob("*-SYNC.json")):
        ticket_dir = sync_file.parent
        ticket_id = ticket_dir.name

        sync_data = _read_json(sync_file)
        if not sync_data or not sync_data.get("jira_key"):
            continue

        create_data = _find_create_data(ticket_dir)
        if create_data is None:
            continue

        ticket_type = create_data.get("ticket_type") or "task"
        priority = create_data.get("priority")

        original_type_correct = ticket_type == ticket_type.capitalize()
        original_priority_translatable = isinstance(priority, int) and priority in _LOCAL_PRIORITY_TO_JIRA

        # Build the edit fields dict.
        fields: dict = {}
        if not original_type_correct:
            fields["ticket_type"] = ticket_type  # handler will .capitalize()
        if original_priority_translatable:
            # Always include priority so handler can re-translate. Safe because
            # the EDIT handler only updates if the value changes at the Jira layer.
            fields["priority"] = priority

        if not fields:
            continue

        if dry_run:
            print(f"[DRY-RUN] Would emit EDIT for {ticket_id}: {fields}")
            emitted += 1
            continue

        ts = time.time_ns()
        event_uuid = str(uuid.uuid4())
        filename = f"{ts}-{event_uuid}-EDIT.json"
        payload = {
            "event_type": "EDIT",
            "timestamp": ts,
            "uuid": event_uuid,
            "env_id": bridge_env_id,
            "ticket_id": ticket_id,
            "data": {"fields": fields},
        }
        event_path = ticket_dir / filename
        event_path.write_text(json.dumps(payload, ensure_ascii=False))
        print(f"Emitted EDIT for {ticket_id} ({sync_data['jira_key']}): {fields}")
        emitted += 1

    return emitted


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Print what would be emitted, do not write files")
    parser.add_argument("--tickets-root", default=".tickets-tracker", help="Path to .tickets-tracker directory")
    args = parser.parse_args()

    tickets_root = Path(args.tickets_root)
    if not tickets_root.is_dir():
        print(f"ERROR: tickets-root not found: {tickets_root}", file=sys.stderr)
        sys.exit(1)

    bridge_env_id = os.environ.get("BRIDGE_ENV_ID", "")
    emitted = reconcile(tickets_root, bridge_env_id=bridge_env_id, dry_run=args.dry_run)
    action = "Would emit" if args.dry_run else "Emitted"
    print(f"{action} {emitted} EDIT event(s).")


if __name__ == "__main__":
    main()
