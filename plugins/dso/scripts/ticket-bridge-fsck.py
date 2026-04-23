#!/usr/bin/env python3
"""Bridge-specific fsck audit tool for the ticket system.

Scans .tickets-tracker/ for bridge mapping anomalies:
  - Orphaned jira_key mappings (SYNC event exists but no CREATE event)
  - Duplicate Jira mappings (multiple tickets share the same jira_key)
  - Stale SYNC events (most recent SYNC > 30 days old, no BRIDGE_ALERT activity)
  - Unresolved BRIDGE_ALERT counts

Usage:
    python3 ticket-bridge-fsck.py [--tickets-tracker=<path>]
    ticket bridge-fsck

Module interface:
    audit_bridge_mappings(tickets_tracker: Path) -> dict
        Returns a findings dict with keys:
          - 'orphaned': list of {ticket_id, jira_key}
          - 'duplicates': list of {jira_key, ticket_ids}
          - 'stale': list of {ticket_id, jira_key, last_sync_ts}

Exit codes:
    0 — no issues found
    1 — one or more issues found
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_STALE_THRESHOLD_NS = 30 * 24 * 3600 * 1_000_000_000  # 30 days in nanoseconds
_NS_THRESHOLD = 1_000_000_000_000  # timestamps >= this are nanosecond-scale

# ---------------------------------------------------------------------------
# Core audit logic
# ---------------------------------------------------------------------------


def _read_json(path: Path) -> dict | None:
    """Read a JSON file, returning None on any parse or IO error."""
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def _to_ns(ts: int | float) -> int:
    """Normalize a timestamp to nanoseconds, handling legacy seconds-scale values."""
    ts_int = int(ts)
    return ts_int * 1_000_000_000 if ts_int < _NS_THRESHOLD else ts_int


def audit_bridge_mappings(
    tickets_tracker: Path,
    now_ts: int | None = None,
) -> dict:
    """Scan all ticket directories under tickets_tracker for bridge anomalies.

    Args:
        tickets_tracker: Path to the .tickets-tracker directory.
        now_ts: Optional reference timestamp (UTC epoch nanoseconds) to use as
            'now' for stale-detection calculations. Defaults to time.time_ns().
            Pass an explicit value in tests for deterministic results.

    Returns:
        A findings dict with keys:
          - 'orphaned': list of {ticket_id, jira_key}
          - 'duplicates': list of {jira_key, ticket_ids}
          - 'stale': list of {ticket_id, jira_key, last_sync_ts}
    """
    orphaned: list[dict] = []
    duplicates: list[dict] = []
    stale: list[dict] = []

    # jira_key -> list of ticket_ids that claim it via SYNC events
    jira_key_to_tickets: dict[str, list[str]] = {}

    if now_ts is None:
        now_ts = time.time_ns()

    if not tickets_tracker.is_dir():
        return {"orphaned": orphaned, "duplicates": duplicates, "stale": stale}

    for ticket_dir in sorted(tickets_tracker.iterdir()):
        if not ticket_dir.is_dir():
            continue

        ticket_id = ticket_dir.name

        # Collect all event files sorted lexicographically (= chronologically)
        event_files = sorted(ticket_dir.glob("*.json"))

        has_create = False
        sync_events: list[dict] = []
        bridge_alert_events: list[dict] = []

        for event_file in event_files:
            data = _read_json(event_file)
            if data is None:
                continue
            event_type = data.get("event_type", "")
            if event_type == "CREATE":
                has_create = True
            elif event_type == "SYNC":
                sync_events.append(data)
            elif event_type == "BRIDGE_ALERT":
                bridge_alert_events.append(data)

        if not sync_events:
            # No SYNC events in this directory — skip bridge checks
            continue

        # Pick the most recent SYNC event (last in sorted order)
        latest_sync = sync_events[-1]
        jira_key = latest_sync.get("jira_key", "")

        # --- Orphan check: SYNC exists but no CREATE event ---
        if not has_create and jira_key:
            orphaned.append({"ticket_id": ticket_id, "jira_key": jira_key})

        # --- Build jira_key → ticket_ids map for duplicate detection ---
        if jira_key:
            jira_key_to_tickets.setdefault(jira_key, []).append(ticket_id)

        # --- Stale SYNC check ---
        # A SYNC event is stale when:
        #   1. The latest SYNC timestamp is >30 days old.
        #   2. There are no BRIDGE_ALERT events after the latest SYNC.
        latest_sync_ts = latest_sync.get("timestamp", 0)
        if isinstance(latest_sync_ts, (int, float)) and latest_sync_ts > 0:
            # Normalize seconds-scale legacy timestamps to nanoseconds for comparison
            sync_ts_ns = int(latest_sync_ts)
            if sync_ts_ns < _NS_THRESHOLD:
                sync_ts_ns *= 1_000_000_000
            age_ns = now_ts - sync_ts_ns
            if age_ns > _STALE_THRESHOLD_NS:
                # Check for any BRIDGE_ALERT events after the latest SYNC.
                # Normalize alert timestamps to nanoseconds so mixed-precision
                # comparisons (legacy seconds-scale SYNC vs. ns-scale BRIDGE_ALERT)
                # are handled correctly.
                has_post_sync_alert = any(
                    _to_ns(alert.get("timestamp", 0)) > sync_ts_ns
                    for alert in bridge_alert_events
                )
                if not has_post_sync_alert:
                    stale.append(
                        {
                            "ticket_id": ticket_id,
                            "jira_key": jira_key,
                            "last_sync_ts": latest_sync_ts,
                        }
                    )

    # --- Duplicate detection: jira_keys mapped to more than one ticket ---
    for jira_key, ticket_ids in jira_key_to_tickets.items():
        if len(ticket_ids) > 1:
            duplicates.append({"jira_key": jira_key, "ticket_ids": ticket_ids})

    return {"orphaned": orphaned, "duplicates": duplicates, "stale": stale}


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------


def _format_report(findings: dict) -> str:
    """Format the audit findings as a human-readable report."""
    orphaned = findings.get("orphaned", [])
    duplicates = findings.get("duplicates", [])
    stale = findings.get("stale", [])

    lines: list[str] = ["=== Bridge FSck Report ==="]
    lines.append(f"Orphans: {len(orphaned)}" if orphaned else "Orphans: none found")
    lines.append(
        f"Duplicates: {len(duplicates)}" if duplicates else "Duplicates: none found"
    )
    lines.append(f"Stale SYNCs: {len(stale)}" if stale else "Stale SYNCs: none found")

    if orphaned:
        lines.append("")
        lines.append("--- Orphaned Mappings ---")
        for entry in orphaned:
            lines.append(
                f"  orphan: ticket={entry['ticket_id']} jira_key={entry['jira_key']}"
            )

    if duplicates:
        lines.append("")
        lines.append("--- Duplicate Jira Mappings ---")
        for entry in duplicates:
            ticket_list = ", ".join(entry["ticket_ids"])
            lines.append(
                f"  duplicate: jira_key={entry['jira_key']} tickets=[{ticket_list}]"
            )

    if stale:
        lines.append("")
        lines.append("--- Stale SYNC Events ---")
        for entry in stale:
            lines.append(
                f"  stale_sync: ticket={entry['ticket_id']}"
                f" jira_key={entry['jira_key']}"
                f" last_sync_ts={entry['last_sync_ts']}"
            )

    if not (orphaned or duplicates or stale):
        lines.append("")
        lines.append("No issues found.")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Returns 0 on clean, 1 on issues."""
    parser = argparse.ArgumentParser(
        description="Audit bridge mappings in the ticket system for anomalies."
    )
    parser.add_argument(
        "--tickets-tracker",
        default=None,
        help=(
            "Path to the .tickets-tracker directory. "
            "Defaults to TICKETS_TRACKER_DIR env var or "
            "<repo-root>/.tickets-tracker."
        ),
    )
    parser.add_argument(
        "--now-ts",
        type=int,
        default=None,
        help=(
            "Override current timestamp (UTC epoch seconds) for stale detection. "
            "Primarily for testing — omit in production use."
        ),
    )
    args = parser.parse_args(argv)

    # Resolve tracker path: explicit arg > env var > repo root default
    if args.tickets_tracker:
        tracker_path = Path(args.tickets_tracker)
    elif "TICKETS_TRACKER_DIR" in os.environ:
        tracker_path = Path(os.environ["TICKETS_TRACKER_DIR"])
    else:
        # Fall back to repo root detection
        try:
            import subprocess

            result = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                check=True,
            )
            repo_root = Path(result.stdout.strip())
        except Exception:
            repo_root = Path.cwd()
        tracker_path = repo_root / ".tickets-tracker"

    findings = audit_bridge_mappings(tracker_path, now_ts=args.now_ts)
    report = _format_report(findings)
    print(report)

    has_issues = any(findings.get(k) for k in ("orphaned", "duplicates", "stale"))
    return 1 if has_issues else 0


if __name__ == "__main__":
    sys.exit(main())
