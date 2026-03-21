#!/usr/bin/env python3
"""Ticket event reducer: compiles event files to current ticket state.

Reads all event JSON files in a ticket directory, sorts by filename
(lexicographic = chronological per the event format contract), and
folds them into a single state dict.

Usage:
    python3 ticket-reducer.py <ticket_dir_path>

Module interface:
    from ticket_reducer import reduce_ticket  # via importlib for hyphenated filename
    state = reduce_ticket("/path/to/.tickets-tracker/tkt-001")
"""

from __future__ import annotations

import glob
import json
import os
import sys


def reduce_ticket(ticket_dir_path: str | os.PathLike[str]) -> dict | None:
    """Compile all events in ticket_dir_path to current ticket state.

    Returns a dict of the current state, or None if no CREATE event was
    found or the directory is empty.
    """
    ticket_dir = str(ticket_dir_path)
    ticket_id = os.path.basename(ticket_dir)

    # List and sort all event JSON files by filename (lexicographic)
    event_files = sorted(glob.glob(os.path.join(ticket_dir, "*.json")))

    if not event_files:
        return None

    # Initial empty state
    state: dict = {
        "ticket_id": None,
        "ticket_type": None,
        "title": None,
        "status": "open",
        "author": None,
        "created_at": None,
        "env_id": None,
        "parent_id": None,
        "comments": [],
        "deps": [],
    }

    for filepath in event_files:
        try:
            with open(filepath, encoding="utf-8") as f:
                event = json.load(f)
        except (json.JSONDecodeError, OSError):
            print(
                f"WARNING: skipping corrupt event {filepath}",
                file=sys.stderr,
            )
            continue

        event_type = event.get("event_type", "")
        data = event.get("data", {})

        if event_type == "CREATE":
            state["ticket_id"] = ticket_id
            state["ticket_type"] = data.get("ticket_type")
            state["title"] = data.get("title")
            state["author"] = event.get("author")
            state["created_at"] = event.get("timestamp")
            state["env_id"] = event.get("env_id")
            state["parent_id"] = data.get("parent_id") or None
        elif event_type == "STATUS":
            state["status"] = data.get("status", state["status"])
        # Unknown event types are silently ignored (COMMENT, LINK, etc.
        # will be handled in w21-o72z)

    # No CREATE event was processed — return None
    if state["ticket_type"] is None:
        return None

    return state


def main() -> int:
    """CLI entry point: print compiled ticket state as JSON."""
    if len(sys.argv) != 2:
        print("Usage: ticket-reducer.py <ticket_dir_path>", file=sys.stderr)
        return 1

    ticket_dir = sys.argv[1]

    if not os.path.isdir(ticket_dir):
        print(f"Error: directory not found: {ticket_dir}", file=sys.stderr)
        return 1

    state = reduce_ticket(ticket_dir)

    if state is None:
        print(
            f"Error: no CREATE event found in {ticket_dir}",
            file=sys.stderr,
        )
        return 1

    print(json.dumps(state, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
