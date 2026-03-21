#!/usr/bin/env python3
"""Detect tickets that become newly unblocked when a set of tickets is closed.

Usage (CLI):
    python3 ticket-unblock.py <tracker_dir> <ticket_id> [--event-source local-close|sync-resolution]

Module interface:
    detect_newly_unblocked(
        closed_ticket_ids: list[str],
        tracker_dir: str,
        event_source: str,
    ) -> list[str]
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Load ticket-reducer.py via importlib (hyphenated filename)
# ---------------------------------------------------------------------------

_SCRIPTS_DIR = Path(__file__).resolve().parent
_REDUCER_PATH = _SCRIPTS_DIR / "ticket-reducer.py"


def _load_reducer():
    """Load the ticket-reducer module via importlib (hyphenated filename)."""
    spec = importlib.util.spec_from_file_location("ticket_reducer", _REDUCER_PATH)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load ticket-reducer.py from {_REDUCER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


_reducer_module = None


def _get_reducer():
    global _reducer_module
    if _reducer_module is None:
        _reducer_module = _load_reducer()
    return _reducer_module


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

_BLOCKING_RELATIONS = {"blocks", "depends_on"}
_CLOSED_STATUSES = {"closed", "done", "resolved", "cancelled", "wont_fix"}
_VALID_EVENT_SOURCES = {"local-close", "sync-resolution"}


def _is_closed(status: str) -> bool:
    """Return True if a ticket status is considered closed/done."""
    return status in _CLOSED_STATUSES


def detect_newly_unblocked(
    closed_ticket_ids: list[str],
    tracker_dir: str,
    event_source: str,
) -> list[str]:
    """Return ticket IDs that become ready_to_work after closing closed_ticket_ids.

    A ticket is newly unblocked when:
      - Its status is open (not already closed), AND
      - All of its direct blockers (blocks/depends_on relations) are now closed,
        counting closed_ticket_ids as closed regardless of their current state.

    Performs a single batch graph traversal — not one query per closed ticket.

    Args:
        closed_ticket_ids: Ticket IDs that are being closed in this operation.
        tracker_dir: Path to the tickets tracker directory.
        event_source: Either 'local-close' or 'sync-resolution'.

    Returns:
        List of ticket IDs (strings) that are newly unblocked. Empty list if none.

    Raises:
        ValueError: If event_source is not a valid value.
    """
    if event_source not in _VALID_EVENT_SOURCES:
        raise ValueError(
            f"Invalid event_source {event_source!r}. "
            f"Must be one of: {sorted(_VALID_EVENT_SOURCES)}"
        )

    reducer = _get_reducer()
    reduce_ticket = reducer.reduce_ticket

    tracker_path = Path(tracker_dir)
    if not tracker_path.is_dir():
        return []

    # Treat closed_ticket_ids as a set for O(1) lookup.
    newly_closed_set = set(closed_ticket_ids)

    # --------------------------------------------------------------------------
    # Single-pass: load all ticket states at once (batch graph traversal).
    # --------------------------------------------------------------------------
    ticket_states: dict[str, dict] = {}
    for entry in os.scandir(tracker_path):
        if not entry.is_dir():
            continue
        ticket_id = entry.name
        state = reduce_ticket(entry.path)
        if state is None:
            continue
        # Skip error/fsck states — treat as non-existent
        if state.get("status") in ("error", "fsck_needed"):
            continue
        ticket_states[ticket_id] = state

    def ticket_is_closed(ticket_id: str) -> bool:
        """Return True if ticket_id is closed, either actually or in the batch."""
        if ticket_id in newly_closed_set:
            return True
        state = ticket_states.get(ticket_id)
        if state is None:
            # Missing ticket dir → tombstoned, treat as closed
            return True
        return _is_closed(state.get("status", "open"))

    # --------------------------------------------------------------------------
    # Find tickets newly unblocked by the batch close.
    # --------------------------------------------------------------------------
    # Build a reverse map: blocker_id → list of ticket_ids it blocks.
    # deps list in compiled state contains: {target_id, relation, link_uuid}
    # target_id is the ticket being blocked (the LINK event is in the blocker's dir).
    # So state["deps"] for ticket X lists: "X blocks target_id".
    # We need: for each candidate ticket C, find all tickets that block C.
    #
    # Strategy: for each ticket, iterate its deps to find what it blocks,
    # then for each candidate check if all its blockers are now closed.

    # blocked_by[ticket_id] = set of ticket_ids that block it (direct blockers)
    blocked_by: dict[str, set[str]] = {}
    for ticket_id, state in ticket_states.items():
        for dep in state.get("deps", []):
            relation = dep.get("relation")
            if relation not in _BLOCKING_RELATIONS:
                continue
            target_id = dep.get("target_id")
            if not target_id:
                continue
            if relation == "blocks":
                # LINK event is in ticket_id's dir: ticket_id blocks target_id
                blocker_id = ticket_id
                blocked_id = target_id
            else:
                # relation == "depends_on"
                # LINK event is in ticket_id's dir: ticket_id depends_on target_id
                # → target_id is the blocker; ticket_id is the blocked ticket
                blocker_id = target_id
                blocked_id = ticket_id
            if blocked_id not in blocked_by:
                blocked_by[blocked_id] = set()
            blocked_by[blocked_id].add(blocker_id)

    newly_unblocked: list[str] = []

    for ticket_id, state in ticket_states.items():
        # Only consider open tickets (not already closed)
        if _is_closed(state.get("status", "open")):
            continue
        # Skip tickets in the batch being closed
        if ticket_id in newly_closed_set:
            continue

        blockers = blocked_by.get(ticket_id, set())
        if not blockers:
            # No blockers — already unblocked (not "newly" unblocked)
            continue

        # Was this ticket already unblocked BEFORE the batch close?
        # i.e., were all blockers already closed before this operation?
        all_blockers_were_closed_before = all(
            _is_closed(ticket_states.get(b, {}).get("status", "open"))
            if b not in newly_closed_set
            else False  # blocker was open before (it's in newly_closed_set)
            for b in blockers
        )

        if all_blockers_were_closed_before:
            # Already unblocked before the batch — not "newly" unblocked
            continue

        # Are all blockers closed NOW (after the batch)?
        all_blockers_closed_now = all(ticket_is_closed(b) for b in blockers)

        if all_blockers_closed_now:
            newly_unblocked.append(ticket_id)

    return newly_unblocked


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> int:
    """CLI: ticket-unblock.py <tracker_dir> <ticket_id> [--event-source ...]"""
    import argparse

    parser = argparse.ArgumentParser(
        description="Detect tickets newly unblocked when a ticket is closed.",
    )
    parser.add_argument("tracker_dir", help="Path to the tickets tracker directory.")
    parser.add_argument("ticket_id", help="The ticket ID being closed.")
    parser.add_argument(
        "--event-source",
        default="local-close",
        choices=list(_VALID_EVENT_SOURCES),
        help="Source of the close event (default: local-close).",
    )

    args = parser.parse_args()

    try:
        unblocked = detect_newly_unblocked(
            closed_ticket_ids=[args.ticket_id],
            tracker_dir=args.tracker_dir,
            event_source=args.event_source,
        )
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    for ticket_id in unblocked:
        print(f"UNBLOCKED {ticket_id}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
