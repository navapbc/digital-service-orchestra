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

import json
import os
import sys
from typing import Protocol, runtime_checkable

# Ensure the ticket_reducer subpackage (sibling directory) is importable
# regardless of how this script is invoked (direct exec, importlib, etc.).
_SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from ticket_reducer import (  # noqa: E402
    make_error_dict,
    make_initial_state,
    prepare_event_files,
    replay_events,
    write_cache,
)


def _make_error_dict(ticket_id: str, status: str, error: str) -> dict:
    """Build an error-state dict with all standard schema fields (d145-e1a9).

    Thin wrapper — delegates to ticket_reducer.make_error_dict so tests that
    import this symbol directly from this module continue to work.
    """
    return make_error_dict(ticket_id, status, error)


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
        status_by_env: dict[str, list[dict]] = {}
        for event in events:
            if event.get("event_type") == "STATUS":
                env_id = event.get("env_id", "")
                status_by_env.setdefault(env_id, []).append(event)

        # --- Step 2: compute net transitions per env (excluding bridge) ---
        def _net_transitions(status_events: list[dict]) -> int:
            seen_statuses: set[str] = set()
            seen_statuses.add("open")
            count = 0
            for ev in status_events:
                target = ev.get("data", {}).get("status", "")
                if target and target not in seen_statuses:
                    seen_statuses.add(target)
                    count += 1
            return count

        candidate_envs = [
            env_id for env_id in status_by_env if env_id != self.bridge_env_id
        ]

        if not candidate_envs:
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

    ``strategy`` is an optional ReducerStrategy for the sync-events merge path.
    Defaults to LastTimestampWinsStrategy() when None.

    # REVIEW-DEFENSE: The ``strategy`` parameter is intentional groundwork for
    # story dso-w21-05z9 (sync-events conflict resolution), which will wire
    # MostStatusEventsWinsStrategy into this call site.  The parameter exists
    # now to maintain backward compatibility with all existing callers (none of
    # which pass a strategy) while allowing the sync path to inject a custom
    # strategy without changing the function signature.
    """
    if strategy is None:
        strategy = LastTimestampWinsStrategy()

    ticket_dir = os.path.normpath(str(ticket_dir_path))
    ticket_id = os.path.basename(ticket_dir)

    cache_path, dir_hash, event_files, cached = prepare_event_files(ticket_dir)
    if cached is not None:
        return cached
    if not event_files:
        return None

    state = make_initial_state()
    valid_event_count, early_result = replay_events(
        state, event_files, ticket_id, cache_path, dir_hash
    )
    if early_result is not None:
        return early_result

    if state["ticket_type"] is None:
        result: dict | None = (
            make_error_dict(ticket_id, "error", "no_valid_create_event")
            if valid_event_count == 0 and len(event_files) > 0
            else None
        )
    else:
        result = state

    if result is not None:
        write_cache(cache_path, dir_hash, result, ticket_dir)

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
        if entry.startswith("."):
            continue
        entry_path = os.path.join(tracker_path, entry)
        if not os.path.isdir(entry_path):
            continue

        state = reduce_ticket(entry_path)

        if state is None:
            results.append(make_error_dict(entry, "error", "reducer_failed"))
        else:
            results.append(state)

    if exclude_archived:
        results = [r for r in results if not r.get("archived")]

    return results


def main() -> int:
    """CLI entry point: print compiled ticket state as JSON."""
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
        print(f"Error: no CREATE event found in {ticket_dir}", file=sys.stderr)
        return 1

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
