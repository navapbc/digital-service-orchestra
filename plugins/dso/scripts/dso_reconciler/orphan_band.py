#!/usr/bin/env python3
"""Orphan-band: enumerate, plan, gate, and apply orphan anomaly remediations."""

from __future__ import annotations

import argparse
import datetime
import hashlib
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


def _load_attestation():
    """Load _attestation module via importlib."""
    attestation_path = Path(__file__).parent / "_attestation.py"
    spec = importlib.util.spec_from_file_location("_attestation", attestation_path)
    if spec is None:
        raise FileNotFoundError(f"_attestation.py not found at {attestation_path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("_attestation", mod)
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


def cmd_gate(args: argparse.Namespace, repo_root: Path) -> int:
    """Verify attestation before allowing applier to run."""
    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"
    attestation_path = bootstrap_dir / f"orphans-{args.pass_id}.attested.json"
    manifest_path = bootstrap_dir / f"orphans-{args.pass_id}.manifest.json"

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

    # (c) Verify manifest hash matches (F8). Skip when attested.json omits
    # manifest_hash (backward compat with earlier attestations).
    recorded_hash = attested.get("manifest_hash", "")
    if recorded_hash:
        if not manifest_path.exists():
            print("GATE FAIL: manifest missing for hash check", file=sys.stderr)
            return 1
        actual_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        if actual_hash != recorded_hash:
            print("GATE FAIL: manifest hash mismatch", file=sys.stderr)
            return 1

    # (d) Verify the commit is signed and not by a bot
    attestation_mod = _load_attestation()
    ok = attestation_mod.verify_attested_commit(sha, BOT_ALLOWLIST)
    if not ok:
        # Distinguish: check whether signature is invalid or committer is a bot
        proc = subprocess.run(["git", "verify-commit", sha], capture_output=True)
        if proc.returncode != 0:
            print(
                f"GATE FAIL: attestation signature invalid for {sha}", file=sys.stderr
            )
        else:
            print("GATE FAIL: attestation committer is a bot", file=sys.stderr)
        return 1

    print(f"GATE OK: attestation valid for pass {args.pass_id}")
    return 0


def _apply_one(anomaly: dict, repo_root: Path) -> dict:
    """Apply a single orphan anomaly mutation by deleting the local ticket.

    An orphan record has shape ``{ticket_id, jira_key, class_label='orphan',
    side='local-only', proposed_remediation='delete orphan mapping', ...}``.
    "local-only" means a SYNC event exists on the local ticket but no CREATE,
    so the ticket has a Jira reference but is not a real local ticket. The
    only durable remediation is to delete the local ticket via the
    canonical CLI (`dso ticket delete <id> --user-approved`).

    Mirrors the local-only remediation pattern used by duplicates_band's
    `_delete_local_ticket`. Returns the per-anomaly outcome dict including
    the delete subprocess result.
    """
    ticket_id = anomaly.get("ticket_id", "")
    if not ticket_id:
        return {
            "anomaly": anomaly,
            "status": "skipped",
            "reason": "anomaly missing ticket_id",
        }

    cli_shim = repo_root / ".claude" / "scripts" / "dso"
    cli_cmd = str(cli_shim) if cli_shim.exists() else "dso"
    try:
        proc = subprocess.run(
            [cli_cmd, "ticket", "delete", ticket_id, "--user-approved"],
            capture_output=True,
            text=True,
            cwd=str(repo_root),
            timeout=30,
        )
    except FileNotFoundError as exc:
        return {
            "anomaly": anomaly,
            "status": "error",
            "reason": f"ticket CLI not found: {exc}",
        }
    except subprocess.TimeoutExpired:
        return {
            "anomaly": anomaly,
            "status": "error",
            "reason": "ticket delete timed out after 30s",
        }

    if proc.returncode == 0:
        return {"anomaly": anomaly, "status": "ok"}
    return {
        "anomaly": anomaly,
        "status": "error",
        "reason": (proc.stderr or proc.stdout or "non-zero exit").strip(),
        "exit_code": proc.returncode,
    }


def cmd_apply(args: argparse.Namespace, repo_root: Path) -> int:
    """Execute orphan anomaly mutations after gate verification."""
    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"
    manifest_path = bootstrap_dir / f"orphans-{args.pass_id}.manifest.json"
    attestation_path = bootstrap_dir / f"orphans-{args.pass_id}.attested.json"

    # 1. Gate check — manifest must exist
    if not manifest_path.exists():
        print(
            f"APPLY FAIL: manifest missing — {manifest_path}",
            file=sys.stderr,
        )
        return 1

    manifest = json.loads(manifest_path.read_text())
    anomalies = manifest.get("anomalies", [])

    # Gate check — attestation must exist and be valid
    if not attestation_path.exists():
        print(
            f"APPLY FAIL: gate failed — attestation missing at {attestation_path}",
            file=sys.stderr,
        )
        return 1

    attested = json.loads(attestation_path.read_text())
    sha = attested.get("commit_sha", "")
    if not sha:
        print(
            "APPLY FAIL: gate failed — attestation has no commit_sha", file=sys.stderr
        )
        return 1

    attestation_mod = _load_attestation()
    gate_ok = attestation_mod.verify_attested_commit(sha, BOT_ALLOWLIST)
    if not gate_ok:
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    # 2. First-week mutation cap
    # TODO(bug TBD — F12): no producer writes first-pass-date.txt. Until a
    # writer is added in cmd_plan (or a separate bootstrap-init step), the
    # cap is dead code on first invocation — silently bypassed. Tracked as
    # a follow-up bug rather than fixed here because the producer's
    # placement (plan-time vs bootstrap-init) is a design choice.
    first_pass_date_path = bootstrap_dir / "first-pass-date.txt"
    if first_pass_date_path.exists():
        raw_date = first_pass_date_path.read_text().strip()
        first_pass_date = datetime.date.fromisoformat(raw_date)
        today = datetime.date.today()
        days_elapsed = (today - first_pass_date).days
        if days_elapsed < 7 and len(anomalies) > 10:
            print(
                "APPLY FAIL: first-week mutation cap exceeded",
                file=sys.stderr,
            )
            return 1

    # 3. Execute mutations
    outcomes = []
    for anomaly in anomalies:
        outcome = _apply_one(anomaly, repo_root)
        outcomes.append(outcome)

    # 4. Post-pass check
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"
    post_pass = fsck.enumerate_orphan_anomalies(tickets_dir)
    acknowledged_residual = attested.get("acknowledged_residual", 0)
    if len(post_pass) > acknowledged_residual:
        # Write outcomes before exiting so callers can inspect partial results
        outcome_path = bootstrap_dir / f"orphans-{args.pass_id}.outcome.json"
        outcome_path.write_text(json.dumps(outcomes, indent=2))
        print(
            f"APPLY FAIL: post-pass count {len(post_pass)} > residual {acknowledged_residual}",
            file=sys.stderr,
        )
        return 1

    # Write outcomes
    outcome_path = bootstrap_dir / f"orphans-{args.pass_id}.outcome.json"
    outcome_path.write_text(json.dumps(outcomes, indent=2))

    # 5. Success
    print(f"APPLY OK: {len(outcomes)} mutations, post-pass count: {len(post_pass)}")
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

    gate_p = sub.add_parser("gate", help="Verify reviewer attestation")
    gate_p.add_argument("--pass", dest="pass_id", required=True)
    gate_p.add_argument("--repo-root", default=None)

    apply_p = sub.add_parser(
        "apply", help="Execute orphan anomaly mutations after gate verification"
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
