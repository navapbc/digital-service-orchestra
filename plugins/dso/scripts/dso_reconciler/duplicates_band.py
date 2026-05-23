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


def cmd_apply(args: argparse.Namespace, repo_root: Path) -> int:
    """Apply duplicate anomaly remediations: merge labels and close duplicate issues."""
    # Inline gate check — reuse cmd_gate logic
    gate_rc = cmd_gate(args, repo_root)
    if gate_rc != 0:
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"

    manifest_path = bootstrap_dir / f"duplicates-{args.pass_id}.manifest.json"
    manifest = json.loads(manifest_path.read_text())

    attested_path = bootstrap_dir / f"duplicates-{args.pass_id}.attested.json"
    attested = json.loads(attested_path.read_text())
    acknowledged_residual = attested.get("acknowledged_residual", 0)

    acli = _load_acli()

    outcomes: list[dict] = []
    for anomaly in manifest["anomalies"]:
        keeper: str = anomaly["keeper"]
        closees: list[str] = anomaly["closees"]
        jira_key: str = anomaly["jira_key"]

        client = acli.AcliClient()

        # (a) Label union into keeper
        client.update_issue_labels(keeper, anomaly.get("labels", []))

        # (b) For each duplicate: comment then close
        for closee_key in closees:
            client.add_issue_comment(
                keeper, f"Merging duplicate {closee_key} into this issue."
            )
            client.transition_issue(closee_key, "Closed")

        outcomes.append(
            {
                "jira_key": jira_key,
                "keeper": keeper,
                "closees": closees,
                "status": "ok",
            }
        )

    # Post-pass residual check
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"
    post_pass = fsck.enumerate_duplicate_anomalies(tickets_dir)

    if len(post_pass) > acknowledged_residual:
        print(
            f"APPLY FAIL: post-pass count {len(post_pass)} > residual {acknowledged_residual}",
            file=sys.stderr,
        )
        return 1

    # Write apply log
    log_path = bootstrap_dir / f"duplicates-{args.pass_id}.apply.log.json"
    log_path.write_text(json.dumps(outcomes, indent=2))

    print(f"APPLY OK: {len(outcomes)} sets processed, post-pass: {len(post_pass)}")
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

    apply_p = sub.add_parser(
        "apply", help="Apply duplicate anomaly remediations (merge labels + close)"
    )
    apply_p.add_argument(
        "--pass", dest="pass_id", required=True, help="Pass identifier"
    )
    apply_p.add_argument(
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

    if args.command == "gate":
        return cmd_gate(args, repo_root)

    if args.command == "apply":
        return cmd_apply(args, repo_root)

    print(f"ERROR: unknown command {args.command!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
