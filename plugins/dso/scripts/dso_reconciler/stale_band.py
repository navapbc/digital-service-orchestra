#!/usr/bin/env python3
"""Stale-band: enumerate, plan, and review stale SYNC anomaly remediations."""

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


def _load_acli():
    """Load acli-integration module via importlib."""
    acli_path = Path(__file__).parent.parent / "acli-integration.py"
    spec = importlib.util.spec_from_file_location("acli_integration", acli_path)
    if spec is None:
        raise FileNotFoundError(f"acli-integration.py not found at {acli_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("acli_integration", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def cmd_plan(args: argparse.Namespace, repo_root: Path) -> int:
    """Write dry-run manifest of stale SYNC anomalies with Jira property materialization."""
    fsck = _load_fsck()
    acli_mod = _load_acli()

    tickets_dir = repo_root / ".tickets-tracker"
    anomalies = fsck.enumerate_stale_anomalies(tickets_dir)

    jira_url = getattr(args, "acli_url", "") or ""
    acli_token = getattr(args, "acli_token", "") or ""
    client = acli_mod.AcliClient(
        jira_url=jira_url,
        user="",
        api_token=acli_token,
    )

    materialized: list[dict] = []
    for record in anomalies:
        jira_key = record.get("jira_key", "")
        authoritative_local_id = record.get("ticket_id", "")

        try:
            current_property_id = client.get_issue_property(jira_key, "dso_local_id")
        except Exception as exc:
            print(
                f"PLAN FAIL: get_issue_property raised for {jira_key}: {exc}",
                file=sys.stderr,
            )
            return 1

        needs_review = current_property_id != authoritative_local_id

        entry = dict(record)
        entry["jira_key"] = jira_key
        entry["current_property_id"] = current_property_id
        entry["authoritative_local_id"] = authoritative_local_id
        entry["needs_review"] = needs_review
        materialized.append(entry)

    manifest = {
        "pass_id": args.pass_id,
        "anomalies": materialized,
    }

    output_dir = repo_root / "bridge_state" / "bootstrap"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"stale-syncs-{args.pass_id}.manifest.json"
    output_path.write_text(json.dumps(manifest, indent=2))

    print(f"PLAN OK: wrote {len(materialized)} anomalies to {output_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for the stale-band CLI."""
    parser = argparse.ArgumentParser(prog="stale_band")
    sub = parser.add_subparsers(dest="command")

    plan_p = sub.add_parser(
        "plan", help="Write dry-run manifest of stale SYNC anomalies"
    )
    plan_p.add_argument("--pass", dest="pass_id", required=True, help="Pass identifier")
    plan_p.add_argument(
        "--repo-root",
        default=None,
        help="Repository root (default: auto-detect)",
    )
    plan_p.add_argument(
        "--acli-url",
        dest="acli_url",
        default="",
        help="Jira base URL for ACLI REST calls",
    )
    plan_p.add_argument(
        "--acli-token",
        dest="acli_token",
        default="",
        help="Jira API token for ACLI REST calls",
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
