#!/usr/bin/env python3
"""CLI for dso-reconciler health records."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _count_open_tickets(tickets_dir: Path) -> int:
    """Count ticket directories in *tickets_dir* that contain at least one JSON file.

    Each subdirectory with a *.json file is treated as one open ticket entry.
    Returns 0 when *tickets_dir* does not exist.
    """
    if not tickets_dir.is_dir():
        return 0
    count = 0
    for d in tickets_dir.iterdir():
        if d.is_dir() and any(d.glob("*.json")):
            count += 1
    return count


def cmd_summary(args: argparse.Namespace) -> int:
    health_dir = Path(args.health_dir)
    if not health_dir.is_dir():
        print("No health records found.")
        return 0
    records = []
    for f in sorted(health_dir.glob("*.json")):
        try:
            records.append(json.loads(f.read_text()))
        except Exception:  # noqa: BLE001
            continue
    if not records:
        print("No health records found.")
        return 0
    # Print table
    header = f"{'pass_id':<30} {'pre_fsck':>8} {'post_fsck':>9} {'ratio':>6} {'mutations':>9}"
    print(header)
    print("-" * len(header))
    for r in records:
        pre = r.get("pre_pass_fsck_total", 0)
        post = r.get("post_pass_fsck_total", 0)
        ratio = f"{post/pre:.2f}" if pre > 0 else "N/A"
        mutations = r.get("local_mutation_count_at_pass", 0)
        print(
            f"{r.get('pass_id', '?'):<30} {pre:>8} {post:>9} {ratio:>6} {mutations:>9}"
        )
    # Parity check: compare latest health record totals against live ticket store
    if getattr(args, "parity_check", False) and records:
        latest = records[-1]  # most recent by sort order (filenames are sorted)
        health_total = sum(latest.get("per_type_open_counts", {}).values())
        tickets_dir = Path(getattr(args, "tickets_dir", ".tickets-tracker"))
        live_total = _count_open_tickets(tickets_dir)
        tolerance = max(1, int(health_total * 0.05))
        if abs(health_total - live_total) <= tolerance:
            print("PARITY: PASS")
        else:
            delta = live_total - health_total
            print(
                f"PARITY: DRIFT — health_total={health_total} live_total={live_total} delta={delta}"
            )
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="dso-reconciler health CLI")
    parser.add_argument(
        "--health-dir",
        default="bridge_state/health",
        help="Path to health records directory",
    )
    sub = parser.add_subparsers(dest="command")
    summary_p = sub.add_parser("summary", help="Show summary of health records")
    summary_p.add_argument(
        "--parity-check",
        action="store_true",
        help="Compare latest health record against live ticket counts",
    )
    summary_p.add_argument(
        "--tickets-dir",
        default=".tickets-tracker",
        help="Path to ticket store for parity check (default: .tickets-tracker)",
    )
    args = parser.parse_args(argv)
    if args.command == "summary":
        return cmd_summary(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
