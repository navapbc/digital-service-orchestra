#!/usr/bin/env python3
"""Write UNLINK events for all net-active LINKs referencing a deleted ticket.

Usage:
    python3 ticket-delete-unlink-scan.py <tracker_dir> <deleted_id> <env_id> <author>

Output:
    Prints one absolute path per line for each UNLINK event file written.
    Exits 0 on success.

Replaces the inline heredoc in ticket-lib-api.sh ticket_delete() (bugs
0071-a28d, 3932-5199).  Uses reduce_all_tickets() so SNAPSHOT-compressed
events are respected and the scan is O(N) across tickets.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path

_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from ticket_reducer import reduce_all_tickets  # noqa: E402


def _write_unlink(
    source_dir: Path, target_id: str, link_uuid_val: str, env_id: str, author: str
) -> str | None:
    """Write an UNLINK event file; return the dest path or None on error."""
    if not source_dir.is_dir():
        return None
    ts = str(time.time_ns())
    ev_uuid = str(uuid.uuid4())
    event = {
        "event_type": "UNLINK",
        "timestamp": int(ts),
        "uuid": ev_uuid,
        "env_id": env_id,
        "author": author,
        "data": {"link_uuid": link_uuid_val, "target_id": target_id},
    }
    dest = source_dir / f"{ts}-{ev_uuid}-UNLINK.json"
    dest.write_text(json.dumps(event, ensure_ascii=False), encoding="utf-8")
    return str(dest)


def main() -> None:
    if len(sys.argv) != 5:
        print(
            "Usage: ticket-delete-unlink-scan.py "
            "<tracker_dir> <deleted_id> <env_id> <author>",
            file=sys.stderr,
        )
        sys.exit(1)

    tracker_dir, deleted_id, env_id, author = sys.argv[1:]
    tracker_path = Path(tracker_dir)

    all_states = reduce_all_tickets(tracker_dir)

    for state in all_states:
        source_id = state.get("ticket_id", "")
        if not source_id:
            continue
        source_dir = tracker_path / source_id

        if source_id == deleted_id:
            # Outbound links: write UNLINK in deleted ticket's own dir
            for dep in state.get("deps", []):
                link_uuid_val = dep.get("link_uuid", "")
                target_id = dep.get("target_id", "")
                if link_uuid_val and target_id:
                    path = _write_unlink(
                        source_dir, target_id, link_uuid_val, env_id, author
                    )
                    if path:
                        print(path)
        else:
            # Inbound links: other tickets pointing at deleted_id
            for dep in state.get("deps", []):
                if dep.get("target_id") == deleted_id:
                    link_uuid_val = dep.get("link_uuid", "")
                    if link_uuid_val:
                        path = _write_unlink(
                            source_dir, deleted_id, link_uuid_val, env_id, author
                        )
                        if path:
                            print(path)


if __name__ == "__main__":
    main()
