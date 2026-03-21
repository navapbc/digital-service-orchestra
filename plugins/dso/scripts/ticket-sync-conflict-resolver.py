#!/usr/bin/env python3
"""Sync-events conflict resolver for multi-environment ticket event streams.

After a git merge in the split-phase sync-events protocol, multiple
environments may have independently mutated ticket STATUS.  This module
resolves those conflicts using MostStatusEventsWinsStrategy and logs each
decision to <tracker_dir>/conflict-resolutions.jsonl.

Module interface:
    result = resolve_sync_conflicts(tracker_dir, bridge_env_id=None)
    # result: dict[ticket_id, winning_status] — only tickets with conflicts

CLI interface:
    python3 ticket-sync-conflict-resolver.py <tracker_dir> [bridge_env_id]
    Exits 0 on success, 1 on error.  Prints JSONL conflict records to stdout.

Called by _sync_events in plugins/dso/scripts/tk (Phase 4.5 — after flock
release, before push) to deterministically resolve STATUS conflicts from
divergent environments before the merged state is pushed back to origin.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Module loading helpers (hyphenated filenames require importlib)
# ---------------------------------------------------------------------------

_SCRIPTS_DIR = Path(__file__).resolve().parent


def _load_module(name: str) -> object:
    script_path = _SCRIPTS_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), script_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


# ---------------------------------------------------------------------------
# resolve_sync_conflicts
# ---------------------------------------------------------------------------


def resolve_sync_conflicts(
    tracker_dir: str,
    bridge_env_id: str | None = None,
) -> dict[str, str]:
    """Resolve STATUS conflicts for all tickets in tracker_dir.

    Scans every subdirectory of tracker_dir.  For each ticket directory that
    contains STATUS events from two or more distinct env_ids, runs
    MostStatusEventsWinsStrategy to determine the winning env and logs the
    decision via log_conflict_resolution().

    Parameters
    ----------
    tracker_dir:
        Path to the tracker directory (e.g. <repo_root>/.tickets-tracker).
        Each immediate subdirectory is treated as a ticket event store.
    bridge_env_id:
        Optional env_id string for the bridge/sync coordinator environment.
        Passed to MostStatusEventsWinsStrategy to exclude it from winner
        selection.  Pass None when no bridge env is configured.

    Returns
    -------
    dict[str, str]
        Mapping of ticket_id → winning_status for tickets where a conflict
        was detected and resolved.  Single-env tickets are NOT included.
    """
    reducer_mod = _load_module("ticket-reducer")
    conflict_log_mod = _load_module("ticket-conflict-log")

    MostStatusEventsWinsStrategy = getattr(reducer_mod, "MostStatusEventsWinsStrategy")
    log_conflict_resolution = getattr(conflict_log_mod, "log_conflict_resolution")

    results: dict[str, str] = {}

    tracker_path = Path(tracker_dir)
    if not tracker_path.is_dir():
        return results

    # Iterate over each ticket subdirectory
    for entry in sorted(tracker_path.iterdir()):
        if not entry.is_dir():
            continue
        ticket_id = entry.name
        # Skip hidden dirs (e.g. .git)
        if ticket_id.startswith("."):
            continue

        # Load all event JSON files in this ticket dir
        events: list[dict] = []
        for event_file in sorted(entry.glob("*.json")):
            try:
                with open(event_file, encoding="utf-8") as fh:
                    event = json.load(fh)
                events.append(event)
            except (OSError, json.JSONDecodeError):
                continue

        if not events:
            continue

        # Detect whether multiple env_ids contributed STATUS events
        status_env_ids: set[str] = set()
        for event in events:
            if event.get("event_type") == "STATUS":
                env_id = event.get("env_id", "")
                if env_id:
                    status_env_ids.add(env_id)

        # Single-env (or no STATUS events) — no conflict, skip
        candidate_env_ids = status_env_ids - (
            {bridge_env_id} if bridge_env_id else set()
        )
        if len(candidate_env_ids) < 2:
            continue

        # Run conflict resolution strategy
        strategy = MostStatusEventsWinsStrategy(bridge_env_id=bridge_env_id)
        resolved_events = strategy.resolve(events)

        # Determine the winning status from the last STATUS event in resolved list
        winning_status: str | None = None
        for event in reversed(resolved_events):
            if event.get("event_type") == "STATUS":
                winning_status = event.get("data", {}).get("status")
                break

        if winning_status is None:
            continue

        results[ticket_id] = winning_status

        # Count STATUS events per env_id for logging
        event_counts: dict[str, int] = {}
        for event in events:
            if event.get("event_type") == "STATUS":
                env_id = event.get("env_id", "")
                if env_id:
                    event_counts[env_id] = event_counts.get(env_id, 0) + 1

        bridge_env_excluded = (
            bridge_env_id is not None and bridge_env_id in status_env_ids
        )

        log_conflict_resolution(
            tracker_dir=tracker_dir,
            ticket_id=ticket_id,
            env_ids=sorted(status_env_ids),
            event_counts=event_counts,
            winning_state={"status": winning_status, "ticket_id": ticket_id},
            bridge_env_excluded=bridge_env_excluded,
        )

    return results


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> int:
    """CLI entry point: resolve conflicts and print results as JSONL."""
    if len(sys.argv) < 2:
        print(
            "Usage: ticket-sync-conflict-resolver.py <tracker_dir> [bridge_env_id]",
            file=sys.stderr,
        )
        return 1

    tracker_dir = sys.argv[1]
    bridge_env_id: str | None = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.isdir(tracker_dir):
        print(
            f"Error: tracker directory not found: {tracker_dir}",
            file=sys.stderr,
        )
        return 1

    try:
        results = resolve_sync_conflicts(tracker_dir, bridge_env_id=bridge_env_id)
    except Exception as exc:  # noqa: BLE001
        print(f"Error: resolve_sync_conflicts failed: {exc}", file=sys.stderr)
        return 1

    for ticket_id, winning_status in results.items():
        print(
            json.dumps(
                {"ticket_id": ticket_id, "winning_status": winning_status},
                ensure_ascii=False,
            )
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
