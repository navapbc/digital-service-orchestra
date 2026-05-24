#!/usr/bin/env python3
"""Stale-band: enumerate, plan, and review stale SYNC anomaly remediations."""

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

JIRA_PROJECT = os.environ.get("JIRA_PROJECT", "DIG")


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


def _build_acli_client(
    acli_mod,
    *,
    jira_url: str = "",
    user: str = "",
    api_token: str = "",
):
    """Construct an AcliClient from explicit args or JIRA_* env vars.

    F1 fix — AcliClient requires positional jira_url/user/api_token; the
    no-arg constructor used previously raised TypeError on every call.
    Explicit args override env vars; either source must satisfy all three
    required credentials or RuntimeError is raised with an actionable
    message.
    """
    url = jira_url or os.environ.get("JIRA_URL", "")
    usr = user or os.environ.get("JIRA_USER", "")
    tok = api_token or os.environ.get("JIRA_API_TOKEN", "")
    missing = [
        name
        for name, val in (("JIRA_URL", url), ("JIRA_USER", usr), ("JIRA_API_TOKEN", tok))
        if not val
    ]
    if missing:
        raise RuntimeError(
            f"missing JIRA_* environment variables: {', '.join(missing)} "
            "(required to construct AcliClient for stale_band)"
        )
    return acli_mod.AcliClient(
        jira_url=url,
        user=usr,
        api_token=tok,
        jira_project=JIRA_PROJECT,
    )


def cmd_plan(args: argparse.Namespace, repo_root: Path) -> int:
    """Write dry-run manifest of stale SYNC anomalies with Jira property materialization."""
    fsck = _load_fsck()
    acli_mod = _load_acli()

    tickets_dir = repo_root / ".tickets-tracker"
    anomalies = fsck.enumerate_stale_anomalies(tickets_dir)

    jira_url = getattr(args, "acli_url", "") or ""
    acli_token = getattr(args, "acli_token", "") or ""
    # F1 fix: AcliClient needs a user too; pull from env via _build_acli_client.
    client = _build_acli_client(
        acli_mod,
        jira_url=jira_url,
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


def cmd_gate(args: argparse.Namespace, repo_root: Path) -> int:
    """Verify attestation before allowing applier to run."""
    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"
    attestation_path = bootstrap_dir / f"stale-syncs-{args.pass_id}.attested.json"

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

    # (c) Verify manifest hash matches
    manifest_path = bootstrap_dir / f"stale-syncs-{args.pass_id}.manifest.json"
    recorded_hash = attested.get("manifest_hash", "")
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


def cmd_apply(args: argparse.Namespace, repo_root: Path) -> int:
    """Apply reviewed stale SYNC anomaly remediations (labels + property updates)."""
    # --- Inline gate check ---
    bootstrap_dir = repo_root / "bridge_state" / "bootstrap"
    attestation_path = bootstrap_dir / f"stale-syncs-{args.pass_id}.attested.json"

    if not attestation_path.exists():
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    attested = json.loads(attestation_path.read_text())
    sha = attested.get("commit_sha", "")
    if not sha:
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    manifest_path = bootstrap_dir / f"stale-syncs-{args.pass_id}.manifest.json"
    # F13 fix: bail with a clear message rather than letting read_bytes() raise.
    if not manifest_path.exists():
        print("APPLY FAIL: manifest missing", file=sys.stderr)
        return 1
    recorded_hash = attested.get("manifest_hash", "")
    actual_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    if actual_hash != recorded_hash:
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    attestation_mod = _load_attestation()
    ok = attestation_mod.verify_attested_commit(sha, BOT_ALLOWLIST)
    if not ok:
        print("APPLY FAIL: gate failed", file=sys.stderr)
        return 1

    # --- Load manifest and attestation ---
    manifest = json.loads(manifest_path.read_text())
    acknowledged_residual = attested.get("acknowledged_residual", 0)

    # --- Apply anomalies ---
    # F1 fix: construct AcliClient once with proper credentials (was AcliClient()
    # per iteration, which raised TypeError on the no-arg ctor — original crash).
    # Mutation surface translation: AcliClient does not expose
    # `update_issue_labels` or `update_issue_property` as named methods, but
    # the underlying capabilities exist via `add_label` (single label add) and
    # `set_issue_property` (property write). Translate the calls accordingly:
    # for a labels list, loop and add each; for the resolved-marker property,
    # call set_issue_property directly. Bug TBD tracks adding bulk-labels
    # adapter if performance becomes a concern.
    acli = _load_acli()
    client = _build_acli_client(acli)
    applied: list[dict] = []
    skipped: list[dict] = []

    for anomaly in manifest["anomalies"]:
        if anomaly.get("needs_review", False):
            skipped.append(anomaly)
            continue
        jira_key = anomaly.get("jira_key", "")
        # F10 fix + adapter translation: pass the labels list (or empty),
        # not the entire anomaly dict; loop add_label since AcliClient has
        # no batch labels API.
        for _label in anomaly.get("labels", []):
            client.add_label(jira_key, _label)
        client.set_issue_property(jira_key, "dso_stale_sync_resolved", True)
        applied.append(anomaly)

    # --- Post-pass check ---
    fsck = _load_fsck()
    tickets_dir = repo_root / ".tickets-tracker"
    post_pass = fsck.enumerate_stale_anomalies(tickets_dir)

    expected_residual = len(skipped)
    residual_threshold = max(acknowledged_residual, expected_residual)
    if len(post_pass) > residual_threshold:
        print(
            f"APPLY FAIL: post-pass count {len(post_pass)} > residual {residual_threshold}",
            file=sys.stderr,
        )
        return 1

    # --- Write result ---
    output_path = bootstrap_dir / f"stale-syncs-{args.pass_id}.applied.json"
    output_path.write_text(
        json.dumps({"applied": applied, "skipped": skipped}, indent=2)
    )

    print(
        f"APPLY OK: {len(applied)} applied, {len(skipped)} skipped, post-pass: {len(post_pass)}"
    )
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

    gate_p = sub.add_parser("gate", help="Verify reviewer attestation")
    gate_p.add_argument("--pass", dest="pass_id", required=True)
    gate_p.add_argument("--repo-root", default=None)

    apply_p = sub.add_parser("apply", help="Apply stale SYNC anomaly remediations")
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
