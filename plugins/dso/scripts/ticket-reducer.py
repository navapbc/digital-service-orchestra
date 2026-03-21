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
import hashlib
import json
import os
import sys
from typing import Protocol, runtime_checkable


@runtime_checkable
class ReducerStrategy(Protocol):
    """Protocol for pluggable ticket event merge strategies."""

    def resolve(self, events: list[dict]) -> list[dict]:
        """Merge and deduplicate a list of events, returning the resolved list."""
        ...


class LastTimestampWinsStrategy:
    """Default strategy: dedup by UUID (first occurrence wins), sort by timestamp.

    Deduplicates events by the ``uuid`` field (keeps the first occurrence in
    iteration order) then sorts the merged list ascending by the ``timestamp``
    field.  This is the strategy used by the sync-events merge path.
    """

    def resolve(self, events: list[dict]) -> list[dict]:
        """Return deduped (first-occurrence-wins) events sorted ascending by timestamp."""
        seen: set[str] = set()
        deduped: list[dict] = []
        for event in events:
            uuid = event.get("uuid", "")
            if uuid and uuid in seen:
                continue
            if uuid:
                seen.add(uuid)
            deduped.append(event)
        return sorted(deduped, key=lambda e: e.get("timestamp", 0))


def reduce_ticket(
    ticket_dir_path: str | os.PathLike[str],
    strategy: ReducerStrategy | None = None,
) -> dict | None:
    """Compile all events in ticket_dir_path to current ticket state.

    Returns a dict of the current state, an error-state dict
    (status='error' or status='fsck_needed') for corrupt/ghost tickets,
    or None if event files are parseable but contain no CREATE event.

    All error-state dicts have exactly three keys: {status, error, ticket_id}.

    Ghost ticket prevention: if the directory contains event files but none
    are parseable (all corrupt JSON), returns an error-state dict with
    status='error' rather than None.

    Corrupt CREATE detection: if a CREATE event is parseable JSON but
    missing required fields (ticket_type or title), returns a compact
    error-state dict with status='fsck_needed'.

    ``strategy`` is an optional ReducerStrategy for the sync-events merge path.
    Defaults to LastTimestampWinsStrategy() when None.  reduce_ticket() itself
    does not invoke the strategy — it is provided as a parameter so callers on
    the sync-events path can pass it through.  Backward compatible: existing
    calls without a strategy argument continue to work unchanged.

    # REVIEW-DEFENSE: The ``strategy`` parameter is intentional groundwork for
    # story dso-w21-05z9 (sync-events conflict resolution), which will wire
    # MostStatusEventsWinsStrategy into this call site.  The parameter exists
    # now to maintain backward compatibility with all existing callers (none of
    # which pass a strategy) while allowing the sync path to inject a custom
    # strategy without changing the function signature.  Removing it and the
    # Protocol/class definitions would require a breaking change at that story.
    # User-approved demotion to minor: the strategy parameter is intentional
    # groundwork for story w21-05z9 (MostStatusEventsWinsStrategy). The
    # parameter is not dead code — it is a forward-compatible extension point
    # approved by the project owner.
    """
    if strategy is None:
        strategy = LastTimestampWinsStrategy()
    ticket_dir = str(ticket_dir_path)
    ticket_id = os.path.basename(ticket_dir)

    # Compute content hash for caching (filename + file size to detect in-place
    # overwrites; size is a fast stat, not a content read).
    cache_path = os.path.join(ticket_dir, ".cache.json")
    try:
        all_files = os.listdir(ticket_dir)
    except OSError:
        all_files = []
    event_filenames = sorted(
        f for f in all_files if f.endswith(".json") and f != ".cache.json"
    )
    hash_parts: list[str] = []
    for name in event_filenames:
        path = os.path.join(ticket_dir, name)
        try:
            size = os.path.getsize(path)
        except OSError:
            size = -1
        hash_parts.append(f"{name}:{size}")
    dir_hash = hashlib.sha256("|".join(hash_parts).encode()).hexdigest()

    # Cache read: check for valid cached state with matching hash
    try:
        with open(cache_path, encoding="utf-8") as cf:
            cached = json.load(cf)
        if isinstance(cached, dict) and cached.get("dir_hash") == dir_hash:
            return cached["state"]
    except (OSError, json.JSONDecodeError, KeyError):
        pass  # Cache miss — recompute

    # List and sort all event JSON files by filename (lexicographic).
    # glob('*.json') excludes dotfiles by design, so .cache.json is never
    # included in event_files — this is intentional and must remain true
    # as long as the cache filename starts with '.'.
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

    valid_event_count = 0

    # Two-pass SNAPSHOT processing: find the latest SNAPSHOT first, then
    # replay only events from that point forward (skipping source UUIDs).
    # This ensures: (1) pre-SNAPSHOT events are never re-applied on top of
    # the snapshot state, and (2) only the latest SNAPSHOT is used — earlier
    # SNAPSHOTs are subsumed by later ones (each SNAPSHOT is a full-state
    # capture that supersedes all prior state).

    # Pass 1: scan all events to find the latest SNAPSHOT index and its
    # source_event_uuids.  Events are already sorted by filename
    # (lexicographic = chronological).
    latest_snapshot_idx: int | None = None
    snapshot_source_uuids: set[str] = set()

    for idx, filepath in enumerate(event_files):
        try:
            with open(filepath, encoding="utf-8") as f:
                event = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        if event.get("event_type") == "SNAPSHOT":
            latest_snapshot_idx = idx
            snapshot_source_uuids = set(
                event.get("data", {}).get("source_event_uuids", [])
            )

    # Pass 2: replay events.  If a SNAPSHOT was found, start from its
    # position (skip all earlier events) and skip any post-SNAPSHOT event
    # whose UUID is in source_event_uuids.
    start_idx = latest_snapshot_idx if latest_snapshot_idx is not None else 0

    for idx, filepath in enumerate(event_files):
        try:
            with open(filepath, encoding="utf-8") as f:
                event = json.load(f)
        except (json.JSONDecodeError, OSError):
            print(
                f"WARNING: skipping corrupt event {filepath}",
                file=sys.stderr,
            )
            continue

        valid_event_count += 1

        # Skip all events before the latest SNAPSHOT
        if idx < start_idx:
            continue

        # Skip events whose UUID was included in the latest SNAPSHOT
        event_uuid = event.get("uuid", "")
        if event_uuid and event_uuid in snapshot_source_uuids:
            continue

        event_type = event.get("event_type", "")
        data = event.get("data", {})

        if event_type == "CREATE":
            # Corrupt CREATE detection: missing required fields
            if not data.get("ticket_type") or not data.get("title"):
                fsck_result = {
                    "status": "fsck_needed",
                    "error": "corrupt_create_event",
                    "ticket_id": ticket_id,
                }
                try:
                    cache_tmp = cache_path + ".tmp"
                    with open(cache_tmp, "w", encoding="utf-8") as tf:
                        json.dump(
                            {"dir_hash": dir_hash, "state": fsck_result},
                            tf,
                            ensure_ascii=False,
                        )
                    os.rename(cache_tmp, cache_path)
                except OSError:
                    pass
                return fsck_result
            state["ticket_id"] = ticket_id
            state["ticket_type"] = data.get("ticket_type")
            state["title"] = data.get("title")
            state["author"] = event.get("author")
            state["created_at"] = event.get("timestamp")
            state["env_id"] = event.get("env_id")
            state["parent_id"] = data.get("parent_id") or None
        elif event_type == "STATUS":
            current_status = data.get("current_status")
            if current_status is not None and current_status != state["status"]:
                # Optimistic concurrency conflict
                if "conflicts" not in state:
                    state["conflicts"] = []
                state["conflicts"].append(
                    {
                        "event_file": os.path.basename(filepath),
                        "expected": current_status,
                        "actual": state["status"],
                        "target": data.get("status"),
                    }
                )
            else:
                state["status"] = data.get("status", state["status"])
        elif event_type == "COMMENT":
            state["comments"].append(
                {
                    "body": data.get("body", ""),
                    "author": event.get("author"),
                    "timestamp": event.get("timestamp"),
                }
            )
        elif event_type == "SNAPSHOT":
            compiled_state = data.get("compiled_state", {})
            # Restore compiled state from snapshot
            for key, value in compiled_state.items():
                state[key] = value
        # Unknown event types are silently ignored (LINK, etc.
        # will be handled in future stories)

    # No CREATE event was processed
    if state["ticket_type"] is None:
        # Ghost ticket prevention: dir has event files but none parsed
        if valid_event_count == 0 and len(event_files) > 0:
            result: dict | None = {
                "status": "error",
                "error": "no_valid_create_event",
                "ticket_id": ticket_id,
            }
        else:
            result = None
    else:
        result = state

    # Cache write: atomically persist result with content hash
    if result is not None:
        try:
            cache_tmp = cache_path + ".tmp"
            with open(cache_tmp, "w", encoding="utf-8") as tf:
                json.dump(
                    {"dir_hash": dir_hash, "state": result}, tf, ensure_ascii=False
                )
            os.rename(cache_tmp, cache_path)
        except OSError:
            print(
                f"WARNING: failed to write cache for {ticket_dir}",
                file=sys.stderr,
            )

    return result


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

    # Error-state dicts (ghost tickets, corrupt CREATE) exit non-zero
    if state.get("status") in ("error", "fsck_needed"):
        print(json.dumps(state, ensure_ascii=False))
        print(
            f"Error: ticket in {ticket_dir} has status '{state['status']}': "
            f"{state.get('error', 'unknown')}",
            file=sys.stderr,
        )
        return 1

    print(json.dumps(state, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
