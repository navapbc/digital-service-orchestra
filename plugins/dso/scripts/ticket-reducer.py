#!/usr/bin/env python3
"""Ticket event reducer: compiles event files to current ticket state.

Reads all event JSON files in a ticket directory, sorts by filename
(lexicographic = chronological per the event format contract), and
folds them into a single state dict.

Usage:
    python3 ticket-reducer.py <ticket_dir_path>
    python3 ticket-reducer.py --batch <tracker_dir>

Module interface:
    from ticket_reducer import reduce_ticket  # via importlib for hyphenated filename
    state = reduce_ticket("/path/to/.tickets-tracker/tkt-001")
    all_states = reduce_all_tickets("/path/to/.tickets-tracker")
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import sys
from typing import Protocol, runtime_checkable


def _make_error_dict(ticket_id: str, status: str, error: str) -> dict:
    """Build an error-state dict with all standard schema fields (d145-e1a9).

    Ensures consumers iterating ticket_type/title never crash on missing keys,
    regardless of which error path produced the dict.
    """
    return {
        "ticket_id": ticket_id,
        "ticket_type": None,
        "title": f"[{status}] {error} for {ticket_id}",
        "status": status,
        "error": error,
        "author": None,
        "created_at": None,
        "env_id": None,
        "parent_id": None,
        "priority": None,
        "assignee": None,
        "description": "",
        "tags": [],
        "comments": [],
        "deps": [],
        "bridge_alerts": [],
        "reverts": [],
    }


@runtime_checkable
class ReducerStrategy(Protocol):
    """Protocol for pluggable ticket event merge strategies."""

    def resolve(self, events: list[dict]) -> list[dict]:
        """Merge and deduplicate a list of events, returning the resolved list."""
        ...


class MostStatusEventsWinsStrategy:
    """Conflict resolution strategy: env with most net STATUS transitions wins.

    "Net transition" = a STATUS event that moves to a status not previously seen
    in that env's history.  Reverts (returning to a prior status) do not count.

    Tie-breaking: when two envs have equal net transition counts, the env whose
    final STATUS event has the latest timestamp wins.

    The bridge env (if provided via ``bridge_env_id``) is excluded from the
    net-transition count and from winner selection.

    resolve() returns all events with STATUS events from losing envs removed,
    sorted ascending by timestamp.  This lets callers find the authoritative
    final status by reading the last STATUS event in the returned list.
    """

    def __init__(self, bridge_env_id: str | None = None) -> None:
        self.bridge_env_id = bridge_env_id

    def resolve(self, events: list[dict]) -> list[dict]:
        """Return events with only the winning env's STATUS events, sorted by timestamp."""
        # --- Step 1: gather STATUS events grouped by env_id ---
        # env_id → list of STATUS events in input order
        status_by_env: dict[str, list[dict]] = {}
        for event in events:
            if event.get("event_type") == "STATUS":
                env_id = event.get("env_id", "")
                status_by_env.setdefault(env_id, []).append(event)

        # --- Step 2: compute net transitions per env (excluding bridge) ---
        # net transition = move to a status not previously seen in this env's history
        def _net_transitions(status_events: list[dict]) -> int:
            seen_statuses: set[str] = set()
            # implicit starting status is "open"
            seen_statuses.add("open")
            count = 0
            for ev in status_events:
                target = ev.get("data", {}).get("status", "")
                if target and target not in seen_statuses:
                    seen_statuses.add(target)
                    count += 1
            return count

        # Only consider non-bridge envs for winner selection
        candidate_envs = [
            env_id for env_id in status_by_env if env_id != self.bridge_env_id
        ]

        if not candidate_envs:
            # No candidates (e.g. only bridge env has STATUS events, or no STATUS events)
            return sorted(events, key=lambda e: e.get("timestamp", 0))

        # --- Step 3: select winner ---
        def _sort_key(env_id: str) -> tuple[int, int]:
            evs = status_by_env[env_id]
            net = _net_transitions(evs)
            latest_ts = max(e.get("timestamp", 0) for e in evs)
            return (net, latest_ts)

        winner_env_id = max(candidate_envs, key=_sort_key)

        # --- Step 4: build result — drop STATUS events from losing envs ---
        losing_env_ids = set(status_by_env.keys()) - {winner_env_id}
        result: list[dict] = []
        for event in events:
            if (
                event.get("event_type") == "STATUS"
                and event.get("env_id") in losing_env_ids
            ):
                continue
            result.append(event)

        return sorted(result, key=lambda e: e.get("timestamp", 0))


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
    ticket_dir = os.path.normpath(str(ticket_dir_path))
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

    # List and sort all event JSON files.
    # glob('*.json') excludes dotfiles by design, so .cache.json is never
    # included in event_files — this is intentional and must remain true
    # as long as the cache filename starts with '.'.
    #
    # Sort key: (timestamp_segment, event_type_order, full_basename)
    # - timestamp_segment: first '-'-delimited field preserves chronological order
    # - event_type_order: LINK=0, UNLINK=1 ensures LINK always replays before UNLINK
    #   at the same Unix-second timestamp, even when the UNLINK filename's UUID sorts
    #   alphabetically before the LINK UUID (dso-jwan fix)
    # - full_basename: stable tiebreaker for remaining ambiguity within same type+timestamp
    _EVENT_TYPE_ORDER = {"LINK": 0, "UNLINK": 1}

    def _event_sort_key(path: str) -> tuple[str, int, str]:
        name = os.path.basename(path)
        ts_segment = name.split("-")[0]
        # Extract event type from the stem before ".json" (last '-'-delimited token)
        stem = name[: -len(".json")] if name.endswith(".json") else name
        event_type = stem.rsplit("-", 1)[-1]
        return (ts_segment, _EVENT_TYPE_ORDER.get(event_type, 99), name)

    event_files = sorted(
        glob.glob(os.path.join(ticket_dir, "*.json")), key=_event_sort_key
    )

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
        "priority": None,
        "assignee": None,
        "description": "",
        "tags": [],
        "comments": [],
        "deps": [],
        "bridge_alerts": [],
        "reverts": [],
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
                fsck_result = _make_error_dict(
                    ticket_id, "fsck_needed", "corrupt_create_event"
                )
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
            state["priority"] = data.get("priority")
            state["assignee"] = data.get("assignee")
            state["description"] = data.get("description") or ""
            state["tags"] = data.get("tags", [])
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
            _raw_body = data.get("body")
            # Coerce non-string bodies (e.g. Jira ADF dicts) to JSON string so
            # downstream string-parsing consumers never receive a dict (b108-f088).
            # Use explicit None check — truthiness check treats {} as absent (6bc8-91bc).
            if _raw_body is None:
                _raw_body = ""
            elif not isinstance(_raw_body, str):
                _raw_body = json.dumps(_raw_body)
            state["comments"].append(
                {
                    "body": _raw_body,
                    "author": event.get("author"),
                    "timestamp": event.get("timestamp"),
                }
            )
        elif event_type == "LINK":
            state["deps"].append(
                {
                    "target_id": data.get("target_id", data.get("target", "")),
                    "relation": data.get("relation", ""),
                    "link_uuid": event["uuid"],
                }
            )
        elif event_type == "UNLINK":
            link_uuid_to_remove = data.get("link_uuid")
            state["deps"] = [
                d for d in state["deps"] if d.get("link_uuid") != link_uuid_to_remove
            ]
        elif event_type == "BRIDGE_ALERT":
            # Normalize reason: prefer data.alert_type (inbound format), fall back to
            # data.reason (outbound format), then data.detail, then empty string.
            reason = (
                data.get("alert_type") or data.get("reason") or data.get("detail") or ""
            )
            if data.get("resolved"):
                # Resolution event: mark the referenced alert as resolved.
                # resolves_uuid (test contract) takes precedence over alert_uuid (ticket spec).
                target_uuid = data.get("resolves_uuid") or data.get("alert_uuid")
                matched = False
                for existing in state["bridge_alerts"]:
                    if existing.get("uuid") == target_uuid:
                        existing["resolved"] = True
                        matched = True
                if not matched:
                    # No matching alert found — record the resolution event itself
                    state["bridge_alerts"].append(
                        {
                            "uuid": event_uuid,
                            "reason": reason,
                            "timestamp": event.get("timestamp"),
                            "resolved": True,
                        }
                    )
            else:
                state["bridge_alerts"].append(
                    {
                        "uuid": event_uuid,
                        "reason": reason,
                        "timestamp": event.get("timestamp"),
                        "resolved": False,
                    }
                )
        elif event_type == "REVERT":
            state["reverts"].append(
                {
                    "uuid": event_uuid,
                    "target_event_uuid": data.get("target_event_uuid"),
                    "target_event_type": data.get("target_event_type"),
                    "reason": data.get("reason", ""),
                    "timestamp": event.get("timestamp"),
                    "author": event.get("author"),
                }
            )
        elif event_type == "EDIT":
            fields = data.get("fields", {})
            for field_name, new_value in fields.items():
                if field_name not in state:
                    continue
                if field_name == "tags":
                    # Tags stored as comma-separated string in event; convert to list.
                    # If the value is already a list (e.g. from a SNAPSHOT), keep it.
                    if isinstance(new_value, list):
                        state["tags"] = new_value
                    elif isinstance(new_value, str):
                        state["tags"] = [
                            t.strip() for t in new_value.split(",") if t.strip()
                        ]
                    else:
                        state["tags"] = []
                else:
                    state[field_name] = new_value
        elif event_type == "ARCHIVED":
            state["archived"] = True
        elif event_type == "SNAPSHOT":
            compiled_state = data.get("compiled_state", {})
            # Restore compiled state from snapshot
            for key, value in compiled_state.items():
                state[key] = value
        # Unknown event types are silently ignored

    # No CREATE event was processed
    if state["ticket_type"] is None:
        # Ghost ticket prevention: dir has event files but none parsed
        if valid_event_count == 0 and len(event_files) > 0:
            result: dict | None = _make_error_dict(
                ticket_id, "error", "no_valid_create_event"
            )
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


def reduce_all_tickets(
    tracker_dir: str | os.PathLike[str],
    exclude_archived: bool = False,
) -> list[dict]:
    """Batch-reduce all tickets in tracker_dir.

    Lists all non-hidden subdirectories in tracker_dir, calls reduce_ticket()
    for each, and collects results into a list.  For directories where
    reduce_ticket() returns None (no CREATE event), emits a fallback error
    dict matching the pattern in ticket-list.sh lines 96-103.

    Returns a list of compiled ticket state dicts (or error-state dicts).
    """
    tracker_path = os.path.normpath(str(tracker_dir))
    results: list[dict] = []

    try:
        entries = sorted(os.listdir(tracker_path))
    except OSError:
        return results

    for entry in entries:
        # Skip hidden directories
        if entry.startswith("."):
            continue
        entry_path = os.path.join(tracker_path, entry)
        if not os.path.isdir(entry_path):
            continue

        state = reduce_ticket(entry_path)

        if state is None:
            # Fallback: no CREATE event — use standard error dict (d145-e1a9).
            results.append(_make_error_dict(entry, "error", "reducer_failed"))
        else:
            results.append(state)

    if exclude_archived:
        results = [r for r in results if not r.get("archived")]

    return results


def main() -> int:
    """CLI entry point: print compiled ticket state as JSON."""
    # Handle --batch mode (with optional --exclude-archived)
    args = sys.argv[1:]
    exclude_archived = False
    if "--exclude-archived" in args:
        exclude_archived = True
        args = [a for a in args if a != "--exclude-archived"]

    if len(args) == 2 and args[0] == "--batch":
        batch_dir = args[1]
        if not os.path.isdir(batch_dir):
            print(f"Error: directory not found: {batch_dir}", file=sys.stderr)
            return 1
        results = reduce_all_tickets(batch_dir, exclude_archived=exclude_archived)
        print(json.dumps(results, ensure_ascii=False))
        return 0

    if len(args) != 1:
        print("Usage: ticket-reducer.py <ticket_dir_path>", file=sys.stderr)
        print(
            "       ticket-reducer.py --batch [--exclude-archived] <tracker_dir>",
            file=sys.stderr,
        )
        return 1

    ticket_dir = args[0]

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
