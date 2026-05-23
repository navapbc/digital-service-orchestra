#!/usr/bin/env python3
"""Duplicates-band: enumerate and plan duplicate anomaly remediations."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

BOT_ALLOWLIST = [
    "github-actions[bot]@users.noreply.github.com",
    "noreply@github.com",
]

# Resolve the host repo's ticket CLI shim. Bands run under the repo root,
# and the shim is installed at .claude/scripts/dso in every consumer.
_DSO_CLI = "dso"


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
    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"
    attestation_path = bootstrap_dir / f"duplicates-{args.pass_id}.attested.json"
    manifest_path = bootstrap_dir / f"duplicates-{args.pass_id}.manifest.json"

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

    # (c) Verify manifest hash matches (F8). Skip the check when the
    # attestation omits manifest_hash entirely (backward compat with
    # earlier attestations that predate this field).
    recorded_hash = attested.get("manifest_hash", "")
    if recorded_hash:
        if not manifest_path.exists():
            print("GATE FAIL: manifest missing for hash check", file=sys.stderr)
            return 1
        actual_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        if actual_hash != recorded_hash:
            print("GATE FAIL: manifest hash mismatch", file=sys.stderr)
            return 1

    # (d) Verify the commit signature
    proc = subprocess.run(["git", "verify-commit", sha], capture_output=True)
    if proc.returncode != 0:
        print(f"GATE FAIL: attestation signature invalid for {sha}", file=sys.stderr)
        return 1

    # (e) Check committer is not a bot
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


def _delete_local_ticket(ticket_id: str, repo_root: Path) -> tuple[int, str]:
    """Delete a local ticket mapping via the dso ticket CLI.

    Used by cmd_apply to clear duplicate local-side mappings without
    touching Jira (F2 — duplicate sets are N local tickets sharing one
    jira_key; remediation is local-only). Returns (returncode, stderr-or-msg).
    """
    cli_shim = repo_root / ".claude" / "scripts" / "dso"
    cli_cmd = str(cli_shim) if cli_shim.exists() else _DSO_CLI
    try:
        proc = subprocess.run(
            [
                cli_cmd,
                "ticket",
                "delete",
                ticket_id,
                "--user-approved",
            ],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
        )
        return proc.returncode, (proc.stderr or proc.stdout or "").strip()
    except FileNotFoundError as exc:
        return 1, f"ticket CLI not found: {exc}"


def cmd_apply(args: argparse.Namespace, repo_root: Path) -> int:
    """Apply duplicate anomaly remediations by deleting duplicate local mappings.

    F2 fix: a duplicate set is N local ticket mappings that all point to
    ONE Jira key. The right remediation is to delete N-1 local mappings
    (the closees) via the local ticket CLI and leave the Jira issue
    alone — Jira has nothing to remediate because it owns a single issue,
    not N. The previous implementation passed local ticket UUIDs to
    Jira-key APIs (add_issue_comment, transition_issue) which would have
    crashed or silently mutated unrelated Jira issues.

    F5 follow-on: with Jira side-effects removed, the previous label
    union into the keeper is no longer applicable — there is no remote
    keeper to receive a union. The label-union call has been deleted
    rather than left as a silent no-op.
    """
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

    outcomes: list[dict] = []
    for anomaly in manifest["anomalies"]:
        keeper: str = anomaly["keeper"]
        closees: list[str] = anomaly["closees"]
        jira_key: str = anomaly["jira_key"]

        # Delete each duplicate local mapping. The keeper stays. Jira is
        # not touched (it owns a single issue with N local-side mappings;
        # Jira has nothing to remediate).
        delete_results: list[dict] = []
        all_ok = True
        for closee_id in closees:
            rc, msg = _delete_local_ticket(closee_id, repo_root)
            delete_results.append(
                {"ticket_id": closee_id, "rc": rc, "message": msg}
            )
            if rc != 0:
                all_ok = False

        outcomes.append(
            {
                "jira_key": jira_key,
                "keeper": keeper,
                "closees": closees,
                "deletes": delete_results,
                "status": "ok" if all_ok else "partial",
            }
        )

    # Post-pass residual check
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"
    post_pass = fsck.enumerate_duplicate_anomalies(tickets_dir)

    if len(post_pass) > acknowledged_residual:
        # Write log before exit so operators can inspect partial results.
        log_path = bootstrap_dir / f"duplicates-{args.pass_id}.apply.log.json"
        log_path.write_text(json.dumps(outcomes, indent=2))
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
