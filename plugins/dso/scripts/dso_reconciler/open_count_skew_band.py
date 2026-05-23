#!/usr/bin/env python3
"""Open-count-skew band: plan, gate, and apply open-count type skew remediations."""

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
    """Write dry-run manifest of open-count type skew anomalies."""
    fsck = _load_fsck()

    tickets_dir = repo_root / ".tickets-tracker"
    anomalies = fsck.enumerate_open_count_skew_anomalies(tickets_dir)

    manifest = {
        "pass_id": args.pass_id,
        "anomalies": anomalies,
    }

    output_dir = repo_root / "bridge_state" / "bootstrap"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"open-count-skew-{args.pass_id}.manifest.json"
    output_path.write_text(json.dumps(manifest, indent=2))

    print(f"PLAN OK: wrote {len(anomalies)} type skews to {output_path}")
    return 0


def cmd_gate(args: argparse.Namespace, repo_root: Path) -> int:
    """Verify attestation before allowing applier to run."""
    attestation_path = (
        repo_root
        / "bridge_state"
        / "bootstrap"
        / f"open-count-skew-{args.pass_id}.attested.json"
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

    # (c) Verify the commit is signed and not by a bot
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


def cmd_apply(args: argparse.Namespace, repo_root: Path) -> int:
    """Apply open-count type skew remediations using local-wins strategy."""
    # --- Inline gate check ---
    if cmd_gate(args, repo_root) != 0:
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"

    # --- Load manifest and attestation ---
    manifest_path = bootstrap_dir / f"open-count-skew-{args.pass_id}.manifest.json"
    attestation_path = bootstrap_dir / f"open-count-skew-{args.pass_id}.attested.json"

    manifest = json.loads(manifest_path.read_text())
    attested = json.loads(attestation_path.read_text())
    acknowledged_residual = attested.get("acknowledged_residual", 5)

    # --- Apply anomalies ---
    acli = _load_acli()
    client = acli.AcliClient()
    outcomes: list[dict] = []

    for anomaly in manifest["anomalies"]:
        delta = anomaly["delta"]
        ttype = anomaly["type"]

        if delta > 0:
            # Local has more open tickets than Jira — create surplus in Jira
            for _ in range(delta):
                client.create_issue(type=ttype, summary=f"Reconcile open {ttype} count")
            outcomes.append({"type": ttype, "delta": delta, "action": "created"})
        elif delta < 0:
            # Jira has more open tickets than local — close surplus in Jira
            surplus_issues = client.search_issues(type=ttype)
            for issue in surplus_issues[: abs(delta)]:
                client.transition_issue(issue["key"], "Closed")
            outcomes.append({"type": ttype, "delta": delta, "action": "closed"})
        else:
            outcomes.append({"type": ttype, "delta": 0, "action": "noop"})

    # --- Post-pass check ---
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"
    post_pass = fsck.enumerate_open_count_skew_anomalies(tickets_dir)

    for remaining in post_pass:
        remaining_delta = remaining.get("delta", 0)
        if abs(remaining_delta) > acknowledged_residual:
            rtype = remaining.get("type", "unknown")
            print(
                f"APPLY FAIL: post-pass tolerance exceeded for type {rtype}: "
                f"delta={remaining_delta}",
                file=sys.stderr,
            )
            return 1

    # --- Write result ---
    output_path = bootstrap_dir / f"open-count-skew-{args.pass_id}.applied.json"
    output_path.write_text(json.dumps({"outcomes": outcomes}, indent=2))

    print("APPLY OK: post-pass skew within tolerance")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Entry point for the open-count-skew-band CLI."""
    parser = argparse.ArgumentParser(prog="open_count_skew_band")
    sub = parser.add_subparsers(dest="command")

    plan_p = sub.add_parser(
        "plan", help="Write dry-run manifest of open-count type skew anomalies"
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

    apply_p = sub.add_parser("apply", help="Apply open-count skew remediations")
    apply_p.add_argument("--pass", dest="pass_id", required=True)
    apply_p.add_argument("--repo-root", default=None)

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
