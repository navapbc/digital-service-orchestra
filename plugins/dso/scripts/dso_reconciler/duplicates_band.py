#!/usr/bin/env python3
"""Duplicates-band: enumerate and plan duplicate anomaly remediations."""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

BOT_ALLOWLIST = [
    "github-actions[bot]@users.noreply.github.com",
    "noreply@github.com",
]


def _load_fsck():
    """Load ticket-bridge-fsck module via importlib."""
    # Navigate up from dso_reconciler/ → scripts/ → find ticket-bridge-fsck.py
    fsck_path = Path(__file__).parent.parent / "ticket-bridge-fsck.py"
    spec = importlib.util.spec_from_file_location("ticket_bridge_fsck", fsck_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("ticket_bridge_fsck", mod)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _is_bot_signer(signer_email: str) -> bool:
    # REFACTOR-TARGET: c412
    return signer_email.strip().lower() in [b.lower() for b in BOT_ALLOWLIST]


def cmd_gate(args: argparse.Namespace, repo_root: Path) -> int:
    """Verify attestation before allowing applier to run."""
    attestation_path = (
        repo_root
        / "bridge_state"
        / "bootstrap"
        / f"duplicates-{args.pass_id}.attested.json"
    )

    # (a) Check attestation file exists
    if not attestation_path.exists():
        print(f"GATE FAIL: attestation missing — {attestation_path}", file=sys.stderr)
        return 1

    # (b) Read the attestation commit SHA
    attested = json.loads(attestation_path.read_text())
    sha = attested.get("commit_sha", "")
    if not sha:
        print("GATE FAIL: attestation has no commit_sha", file=sys.stderr)
        return 1

    # (c) Verify the commit signature
    proc = subprocess.run(["git", "verify-commit", sha], capture_output=True)
    if proc.returncode != 0:
        print(f"GATE FAIL: attestation signature invalid for {sha}", file=sys.stderr)
        return 1

    # (d) Check committer is not a bot
    email_proc = subprocess.run(
        ["git", "log", "-1", "--format=%ae", sha],
        capture_output=True,
        text=True,
    )
    committer_email = email_proc.stdout.strip()
    if _is_bot_signer(committer_email):
        print("GATE FAIL: attestation committer is a bot", file=sys.stderr)
        return 1

    print(f"GATE OK: attestation valid for pass {args.pass_id}")
    return 0


def cmd_plan(args: argparse.Namespace, repo_root: Path) -> int:
    """Write dry-run manifest of duplicate anomalies."""
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"

    anomalies = fsck.enumerate_duplicate_anomalies(tickets_dir)

    manifest = {
        "pass_id": args.pass_id,
        "anomalies": anomalies,
    }

    output_dir = repo_root / "bridge_state" / "bootstrap"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"duplicates-{args.pass_id}.manifest.json"
    output_path.write_text(json.dumps(manifest, indent=2))

    print(f"PLAN OK: wrote {len(anomalies)} anomalies to {output_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for the duplicates-band CLI."""
    parser = argparse.ArgumentParser(prog="duplicates_band")
    sub = parser.add_subparsers(dest="command")

    plan_p = sub.add_parser(
        "plan", help="Write dry-run manifest of duplicate anomalies"
    )
    plan_p.add_argument("--pass", dest="pass_id", required=True, help="Pass identifier")
    plan_p.add_argument(
        "--repo-root",
        default=None,
        help="Repository root (default: auto-detect)",
    )

    gate_p = sub.add_parser("gate", help="Verify reviewer attestation")
    gate_p.add_argument("--pass", dest="pass_id", required=True)
    gate_p.add_argument("--repo-root", default=None)

    args = parser.parse_args(argv)

    if args.command is None:
        parser.print_help()
        return 1

    repo_root = Path(args.repo_root) if args.repo_root else Path(__file__).parents[4]

    if args.command == "plan":
        return cmd_plan(args, repo_root)

    if args.command == "gate":
        return cmd_gate(args, repo_root)

    print(f"ERROR: unknown command {args.command!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
