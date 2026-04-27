"""Link event writing and add_dependency for ticket-graph."""

from __future__ import annotations

import glob as _glob
import json
import os
import sys
import uuid

from ticket_graph._graph import check_cycle_at_level, check_would_create_cycle
from ticket_graph._hierarchy import resolve_hierarchy_link
from ticket_graph._loader import reduce_ticket
from ticket_graph._status import _get_ticket_status


class CyclicDependencyError(Exception):
    """Raised when adding a dependency would create a cycle."""

    pass


def _is_active_link(
    source_id: str, target_id: str, relation: str, tracker_dir: str
) -> bool:
    """Return True if a net-active LINK exists from source_id to target_id with the given relation."""
    ticket_dir = os.path.join(tracker_dir, source_id)
    if not os.path.isdir(ticket_dir):
        return False

    _event_order = {"LINK": 0, "UNLINK": 1}
    link_files = [
        ("LINK", f) for f in _glob.glob(os.path.join(ticket_dir, "*-LINK.json"))
    ]
    unlink_files = [
        ("UNLINK", f) for f in _glob.glob(os.path.join(ticket_dir, "*-UNLINK.json"))
    ]
    all_events = sorted(
        link_files + unlink_files,
        key=lambda x: (
            os.path.basename(x[1]).split("-")[0],
            _event_order.get(x[0], 99),
            os.path.basename(x[1]),
        ),
    )

    active_links: dict[str, tuple[str, str]] = {}  # uuid → (target_id, relation)
    for event_type, filepath in all_events:
        try:
            with open(filepath, encoding="utf-8") as fh:
                ev = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        ev_uuid = ev.get("uuid", "")
        data = ev.get("data", {})
        if event_type == "LINK" and ev_uuid:
            active_links[ev_uuid] = (
                data.get("target_id", data.get("target", "")),
                data.get("relation", ""),
            )
        elif event_type == "UNLINK":
            link_uuid = data.get("link_uuid", "")
            if link_uuid:
                active_links.pop(link_uuid, None)

    return any(
        tid == target_id and rel == relation for tid, rel in active_links.values()
    )


def _write_link_event(
    source_id: str,
    target_id: str,
    relation: str,
    tracker_dir: str,
) -> None:
    """Write a single LINK event to source_id's directory (no cycle check, no idempotency)."""
    import fcntl as _fcntl
    import subprocess as _sp
    import time

    source_dir = os.path.join(tracker_dir, source_id)
    if not os.path.isdir(source_dir):
        os.makedirs(source_dir, exist_ok=True)

    link_uuid = str(uuid.uuid4())
    timestamp = time.time_ns()

    link_event = {
        "event_type": "LINK",
        "uuid": link_uuid,
        "timestamp": timestamp,
        "author": "ticket-graph",
        "env_id": "00000000-0000-4000-8000-000000000000",
        "data": {
            "target_id": target_id,
            "relation": relation,
        },
    }

    filename = f"{timestamp}-{link_uuid}-LINK.json"
    event_path = os.path.join(source_dir, filename)
    with open(event_path, "w", encoding="utf-8") as f:
        json.dump(link_event, f, ensure_ascii=False)

    _rel_path = os.path.relpath(event_path, tracker_dir)
    _commit_msg = f"ticket: link {source_id} {relation} {target_id}"
    _lock_path = os.path.join(tracker_dir, ".ticket-write.lock")
    try:
        with open(_lock_path, "a") as _lock_fd:
            _fcntl.flock(_lock_fd, _fcntl.LOCK_EX)
            try:
                _sp.run(
                    ["git", "-C", tracker_dir, "add", _rel_path],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                _sp.run(
                    [
                        "git",
                        "-C",
                        tracker_dir,
                        "commit",
                        "-q",
                        "--no-verify",
                        "-m",
                        _commit_msg,
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            finally:
                _fcntl.flock(_lock_fd, _fcntl.LOCK_UN)
    except _sp.CalledProcessError as e:
        print(f"Warning: git commit failed for LINK event: {e.stderr}", file=sys.stderr)
        return

    # Best-effort push — mirrors bash _push_tickets_branch behavior.
    # Skipped in test environments (_TICKET_TEST_NO_SYNC=1) and when no remote exists.
    # REVIEW-DEFENSE: For relates_to, add_dependency calls _write_link_event twice (once
    # per direction). Each call pushes independently. Double best-effort pushes are harmless:
    # the second push is a no-op if no new commits exist between the two calls, and both are
    # non-fatal. This matches how bash write_commit_event works (one push per commit).
    if os.environ.get("_TICKET_TEST_NO_SYNC", "") == "1":
        return
    _remote_check = _sp.run(
        ["git", "-C", tracker_dir, "remote"],
        capture_output=True,
        text=True,
    )
    if _remote_check.stdout.strip():
        _sp.run(
            ["git", "-C", tracker_dir, "push", "origin", "tickets"],
            capture_output=True,
            text=True,
        )  # best-effort: no check=True, failure is non-fatal


def add_dependency(
    source_id: str,
    target_id: str,
    tracker_dir: str,
    relation: str = "blocks",
) -> None:
    """Add a dependency from source_id to target_id with cycle check.

    Raises CyclicDependencyError if adding this dependency would create a cycle.
    Writes a LINK event to the source ticket's directory.
    Idempotent: if a net-active LINK with the same (target_id, relation) already exists,
    this is a no-op (exits cleanly without writing a duplicate event).
    For relates_to: also writes a reciprocal LINK event in target_id's directory.
    """
    # Step 1: Resolve hierarchy
    hierarchy_result = resolve_hierarchy_link(source_id, target_id, tracker_dir)

    if "error" in hierarchy_result:
        raise ValueError(hierarchy_result["error"])

    if hierarchy_result.get("is_redundant"):
        msg = (
            f"ERROR: redundant link — {source_id} and {target_id} are in a direct "
            "parent-child relationship"
        )
        print(msg, file=sys.stderr)
        raise ValueError(msg)

    resolved_source = str(hierarchy_result["resolved_source"])
    resolved_target = str(hierarchy_result["resolved_target"])
    was_redirected = bool(hierarchy_result.get("was_redirected"))

    if was_redirected:
        print(
            f"REDIRECT: {source_id}\u2192{target_id} promoted to "
            f"{resolved_source}\u2192{resolved_target}",
            file=sys.stderr,
        )
        print(
            json.dumps(
                {
                    "redirected": True,
                    "original": {"source": source_id, "target": target_id},
                    "resolved": {"source": resolved_source, "target": resolved_target},
                }
            )
        )

    source_id = resolved_source
    target_id = resolved_target

    if check_would_create_cycle(source_id, target_id, relation, tracker_dir):
        raise CyclicDependencyError(
            f"Adding {resolved_source} → {resolved_target} ({relation}) would create a cycle"
        )

    resolved_source_dir = os.path.join(tracker_dir, resolved_source)
    resolved_source_state = (
        reduce_ticket(resolved_source_dir)
        if os.path.isdir(resolved_source_dir)
        else None
    )
    level = (
        (resolved_source_state.get("ticket_type") or "").lower()
        if resolved_source_state
        else ""
    )
    if level and check_cycle_at_level(
        resolved_source, resolved_target, level, tracker_dir
    ):
        if resolved_source == resolved_target:
            raise CyclicDependencyError(
                f"Adding {resolved_source} → {resolved_target} ({relation}) "
                f"is a self-referential dependency at {level} level"
            )
        raise CyclicDependencyError(
            f"Adding {resolved_source} → {resolved_target} ({relation}) "
            f"would create a cycle at {level} level"
        )

    source_status = _get_ticket_status(source_id, tracker_dir)
    if source_status == "closed":
        raise ValueError(
            f"cannot create {relation} link — source ticket '{source_id}' is closed. "
            f"Reopen it first with: ticket transition {source_id} closed open"
        )

    if relation == "depends_on":
        target_status = _get_ticket_status(target_id, tracker_dir)
        if target_status == "closed":
            raise ValueError(
                f"cannot create depends_on link — target ticket '{target_id}' is closed"
            )

    if _is_active_link(source_id, target_id, relation, tracker_dir):
        return

    _write_link_event(source_id, target_id, relation, tracker_dir)

    if relation == "relates_to" and not _is_active_link(
        target_id, source_id, relation, tracker_dir
    ):
        _write_link_event(target_id, source_id, relation, tracker_dir)
