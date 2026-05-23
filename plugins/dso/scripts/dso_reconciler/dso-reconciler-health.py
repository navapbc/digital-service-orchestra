#!/usr/bin/env python3
"""CLI for dso-reconciler health records."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


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
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="dso-reconciler health CLI")
    parser.add_argument(
        "--health-dir",
        default="bridge_state/health",
        help="Path to health records directory",
    )
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("summary", help="Show summary of health records")
    args = parser.parse_args(argv)
    if args.command == "summary":
        return cmd_summary(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
