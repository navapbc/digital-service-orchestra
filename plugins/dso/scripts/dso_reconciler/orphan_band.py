#!/usr/bin/env python3
"""Orphan-band: enumerate, plan, gate, and apply orphan anomaly remediations."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


def _load_fsck():
    """Load ticket-bridge-fsck module via importlib."""
    # Navigate up from dso_reconciler/ → scripts/ → find ticket-bridge-fsck.py
    fsck_path = Path(__file__).parent.parent / "ticket-bridge-fsck.py"
    spec = importlib.util.spec_from_file_location("ticket_bridge_fsck", fsck_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ticket_bridge_fsck", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def cmd_plan(args: argparse.Namespace, repo_root: Path) -> int:
    """Write dry-run manifest of orphan anomalies."""
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"

    anomalies = fsck.enumerate_orphan_anomalies(tickets_dir)

    manifest = {
        "pass_id": args.pass_id,
        "anomalies": anomalies,
    }

    output_dir = repo_root / "bridge_state" / "bootstrap"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"orphans-{args.pass_id}.manifest.json"
    output_path.write_text(json.dumps(manifest, indent=2))

    print(f"PLAN OK: wrote {len(anomalies)} anomalies to {output_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for the orphan-band CLI."""
    parser = argparse.ArgumentParser(prog="orphan_band")
    sub = parser.add_subparsers(dest="command")

    plan_p = sub.add_parser("plan", help="Write dry-run manifest of orphan anomalies")
    plan_p.add_argument("--pass", dest="pass_id", required=True, help="Pass identifier")
    plan_p.add_argument(
        "--repo-root",
        default=None,
        help="Repository root (default: auto-detect)",
    )

    args = parser.parse_args(argv)

    if args.command is None:
        parser.print_help()
        return 1

    repo_root = Path(args.repo_root) if args.repo_root else Path(__file__).parents[4]

    if args.command == "plan":
        return cmd_plan(args, repo_root)

    print(f"ERROR: unknown command {args.command!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
