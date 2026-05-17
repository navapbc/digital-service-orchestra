"""dso_ci_review.arbiter_processor - process arbiter rulings into side effects.

Routes BLOCK/DEFER/DROP rulings from the cycle-end arbiter into:
  - BLOCK accumulated list (returned for commit gate)
  - DEFER -> idempotent orphan-task ticket via subprocess (`dso ticket create task`)
            Dedup key: finding_hash + PR/branch scope marker in ticket description
  - DROP -> defense store write (tracker via review-defense-store.sh, always;
            PR-store via review-github-defense-store.sh when PR_NUMBER set)
            Partial-failure semantics: tracker first, PR best-effort, no rollback,
            no BLOCK escalation on PR-store failure
  - All rulings written to arbiter-rulings.json sidecar (atomic write).
    Legacy sidecars (no schema_version) are overwritten with warning.

Public function:
    process_rulings(rulings, finding_map, cycle_num, commit_sha, pr_number,
                    branch_name, ticket_cmd_path, artifacts_dir, repo_root) -> dict
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def _finding_hash_for_dedup(finding: dict) -> str:
    """Stable finding hash for dedup - uses file + line_range + category.

    Falls back to parsing cited_lines='path:line' if file/line_range absent.
    """
    file = finding.get("file", "")
    line_range = finding.get("line_range", "")
    category = finding.get("category", "") or finding.get("dimension", "")

    if not file and finding.get("cited_lines"):
        first = finding["cited_lines"][0] if finding["cited_lines"] else ""
        if ":" in first:
            file, line_range = first.split(":", 1)
        else:
            file = first

    return hashlib.sha256(
        f"{file}|{line_range}|{category}".encode("utf-8")
    ).hexdigest()[:16]


def _dedup_scope(pr_number: int | None, branch_name: str | None) -> str:
    """Scope marker for dedup queries (PR# in CI mode, branch:name locally)."""
    if pr_number is not None:
        return f"#{pr_number}"
    return f"branch:{branch_name or 'unknown'}"


def _query_existing_defer_ticket(
    finding_hash: str, scope: str, ticket_cmd_path: str
) -> str | None:
    """Query existing orphan tickets for matching Finding-Hash + Scope marker.

    Uses --format=llm to get full descriptions; iterates ticket list and checks
    descriptions for the marker pattern. Per AC amendment, query is unbounded
    (--limit=0) to handle pagination and avoid silent dedup misses.

    On collision, verifies ticket status != 'deleted' before treating as a hit
    (handles race-loser self-delete state).
    """
    try:
        result = subprocess.run(
            [
                ticket_cmd_path, "ticket", "list",
                "--tag=orphan:deferred_review",
                "--format=llm",
                "--limit=0",
            ],
            capture_output=True, text=True, check=False, timeout=30,
        )
        if result.returncode != 0:
            return None
        try:
            tickets = json.loads(result.stdout)
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(tickets, list):
            return None
        marker = f"Finding-Hash: {finding_hash} Scope: {scope}"
        for t in tickets:
            if not isinstance(t, dict):
                continue
            desc = t.get("description", "") or ""
            if marker not in desc:
                continue
            tid = t.get("ticket_id") or t.get("id")
            if not tid:
                continue
            # AC amendment: confirm not deleted (handle race-loser self-delete)
            status = t.get("status", "")
            if status == "deleted":
                continue
            return tid
        return None
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        return None


def _create_defer_ticket(
    ruling: dict, finding: dict, finding_hash: str, scope: str,
    cycle_num: int, ticket_cmd_path: str,
) -> str | None:
    """Create orphan-task ticket; return new ticket ID or None on failure."""
    rationale = ruling.get("rationale", "") or ""
    title = f"Deferred review finding: {rationale[:80]}"
    description = (
        f"Arbiter DEFER ruling from cycle {cycle_num}.\n"
        f"Finding-Hash: {finding_hash} Scope: {scope}\n"
        f"Rationale: {rationale}\n"
    )
    cmd = [
        ticket_cmd_path, "ticket", "create", "task", title,
        "--tags=orphan:deferred_review", "--tags=origin:arbiter",
        "--priority=3", "-d", description,
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, check=False, timeout=30
        )
        if result.returncode != 0:
            return None
        # Extract ticket ID from stdout (last whitespace-separated token)
        stdout = (result.stdout or "").strip()
        if not stdout:
            return None
        new_id = stdout.split()[-1]
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        return None

    # AC amendment: race-loser self-delete on creation collision.
    # After creating, re-query: if there's a different ticket with the same
    # Finding-Hash + Scope marker that pre-existed, self-delete this one.
    try:
        existing = _find_race_winner(
            finding_hash, scope, new_id, ticket_cmd_path
        )
        if existing:
            subprocess.run(
                [
                    ticket_cmd_path, "ticket", "delete", new_id,
                    "--user-approved",
                    "--reason=arbiter-dedup race loser",
                ],
                capture_output=True, text=True, check=False, timeout=30,
            )
            return existing
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        pass

    return new_id


def _find_race_winner(
    finding_hash: str, scope: str, our_id: str, ticket_cmd_path: str
) -> str | None:
    """Re-query tickets after create; return another ticket id matching marker.

    Used by race-loser self-delete: if two arbiter runs both create a ticket
    for the same finding, the second detector self-deletes.
    """
    try:
        result = subprocess.run(
            [
                ticket_cmd_path, "ticket", "list",
                "--tag=orphan:deferred_review",
                "--format=llm",
                "--limit=0",
            ],
            capture_output=True, text=True, check=False, timeout=30,
        )
        if result.returncode != 0:
            return None
        tickets = json.loads(result.stdout)
        if not isinstance(tickets, list):
            return None
        marker = f"Finding-Hash: {finding_hash} Scope: {scope}"
        for t in tickets:
            if not isinstance(t, dict):
                continue
            tid = t.get("ticket_id") or t.get("id")
            if not tid or tid == our_id:
                continue
            desc = t.get("description", "") or ""
            if marker in desc and t.get("status") != "deleted":
                return tid
        return None
    except (subprocess.TimeoutExpired, subprocess.SubprocessError,
            json.JSONDecodeError, ValueError):
        return None


def _plugin_scripts_dir(repo_root: str) -> str:
    """Resolve the plugin scripts directory without hard-coding any path.

    Prefers $CLAUDE_PLUGIN_ROOT (set when invoked from the dso plugin). Falls
    back to deriving from this module's own location so callers in tests or
    other contexts also work.
    """
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if plugin_root:
        return os.path.join(plugin_root, "scripts")
    # Derive from this file's path: <repo>/<plugin-path>/scripts/dso_ci_review/this.py
    here = Path(__file__).resolve().parent.parent
    return str(here)


def _write_drop_defense(
    ruling: dict, finding_hash: str, cycle_num: int,
    pr_number: int | None, repo_root: str,
) -> dict:
    """Write DROP defense record. Tracker first, PR best-effort.

    AC amendment: tracker is source of truth (written first); PR-store is a
    best-effort mirror. PR-store failure does NOT roll back the tracker write
    and does NOT escalate to BLOCK. Failure emits a structured
    `drop_pr_store_failed` log line to stderr for observability.

    Returns dict with 'written_to' list and the record content.
    """
    record = {
        "prior_finding_id": finding_hash,
        "defense_type": "dropped_by_arbiter",
        "defense_text": f"Arbiter DROP: {(ruling.get('rationale', '') or '')[:200]}",
        "defender": "code-reviewer-arbiter",
        "cycle_number": cycle_num,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "severity_history": [{
            "cycle": cycle_num,
            "severity": ruling.get("impact_class", "unknown"),
            "relation": "DROPPED",
        }],
        "ticket_id": os.environ.get("DSO_SESSION_TICKET_ID", "UNBOUND"),
    }
    record_json = json.dumps(record)
    written_to: list[str] = []
    scripts_dir = _plugin_scripts_dir(repo_root)

    # 1) Tracker store (always; source of truth, written first)
    tracker_script = os.path.join(scripts_dir, "review-defense-store.sh")
    try:
        result = subprocess.run(
            [tracker_script, "write", record_json],
            capture_output=True, text=True, check=False, timeout=30,
        )
        if result.returncode == 0:
            written_to.append("tracker")
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        pass

    # 2) PR store (conditional on PR_NUMBER; best-effort mirror)
    if pr_number is not None:
        pr_script = os.path.join(scripts_dir, "review-github-defense-store.sh")
        try:
            result = subprocess.run(
                [pr_script, "write", record_json, str(pr_number)],
                capture_output=True, text=True, check=False, timeout=30,
            )
            if result.returncode == 0:
                written_to.append("pr")
            else:
                # AC amendment: structured log on PR-store failure;
                # do NOT escalate to BLOCK, do NOT roll back tracker.
                print(
                    f"drop_pr_store_failed finding_hash={finding_hash} "
                    f"pr={pr_number} returncode={result.returncode}",
                    file=sys.stderr,
                )
        except (subprocess.TimeoutExpired, subprocess.SubprocessError) as e:
            print(
                f"drop_pr_store_failed finding_hash={finding_hash} "
                f"pr={pr_number} error={type(e).__name__}",
                file=sys.stderr,
            )

    return {"written_to": written_to, "record": record}


def _atomic_write_sidecar(path: str, data: str) -> None:
    """Write to temp file in same dir, then rename atomically."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=p.name + ".", dir=str(p.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp_path, str(p))
    except Exception:
        if Path(tmp_path).exists():
            os.unlink(tmp_path)
        raise


def _read_existing_sidecar(path: str) -> dict | None:
    """Read existing sidecar.

    Return None if absent, invalid, or legacy (no schema_version). Legacy
    sidecars are logged so operators can audit unexpected overwrites.
    """
    p = Path(path)
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    schema_version = data.get("schema_version", "")
    if not schema_version or schema_version < "1.0.0":
        # Legacy sidecar - log and treat as overwrite candidate.
        print(
            f"arbiter_processor_legacy_sidecar_detected path={path} "
            f"action=overwrite",
            file=sys.stderr,
        )
        return None
    return data


def process_rulings(
    rulings: list[dict],
    finding_map: dict,
    cycle_num: int,
    commit_sha: str = "",
    pr_number: int | None = None,
    branch_name: str | None = None,
    ticket_cmd_path: str = ".claude/scripts/dso",
    artifacts_dir: str | None = None,
    repo_root: str | None = None,
) -> dict:
    """Process arbiter rulings into side effects.

    Returns:
        {
          "block": [{"ruling": ..., "finding": ..., "finding_hash": ...}, ...],
          "defer_ticket_ids": [str, ...],
          "drop_defense_records": [{"written_to": [...], "record": {...}}, ...],
          "skipped_idempotent": [finding_hash, ...],
        }
    """
    if repo_root is None:
        try:
            repo_root = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError:
            repo_root = os.getcwd()
    if artifacts_dir is None:
        artifacts_dir = os.environ.get("WORKFLOW_PLUGIN_ARTIFACTS_DIR", "/tmp")

    result: dict = {
        "block": [],
        "defer_ticket_ids": [],
        "drop_defense_records": [],
        "skipped_idempotent": [],
    }
    scope = _dedup_scope(pr_number, branch_name)

    for ruling in rulings:
        ruling_type = ruling.get("ruling", "")
        finding_idx = ruling.get("finding_index", 0)
        finding = finding_map.get(finding_idx, {})
        finding_hash = _finding_hash_for_dedup(finding)

        if ruling_type == "BLOCK":
            result["block"].append({
                "ruling": ruling,
                "finding": finding,
                "finding_hash": finding_hash,
            })
        elif ruling_type == "DEFER":
            existing = _query_existing_defer_ticket(
                finding_hash, scope, ticket_cmd_path
            )
            if existing:
                result["skipped_idempotent"].append(finding_hash)
                result["defer_ticket_ids"].append(existing)
            else:
                new_id = _create_defer_ticket(
                    ruling, finding, finding_hash, scope, cycle_num, ticket_cmd_path
                )
                if new_id:
                    result["defer_ticket_ids"].append(new_id)
        elif ruling_type == "DROP":
            drop_result = _write_drop_defense(
                ruling, finding_hash, cycle_num, pr_number, repo_root
            )
            result["drop_defense_records"].append(drop_result)

    # Sidecar: detect legacy + overwrite atomically with deterministic content.
    sidecar_path = os.path.join(artifacts_dir, "arbiter-rulings.json")
    _read_existing_sidecar(sidecar_path)  # logs warning if legacy
    sidecar_data = {
        "schema_version": "1.0.0",
        "commit_sha": commit_sha,
        "cycle_num": cycle_num,
        "rulings": rulings,
        "summary": {
            "block_count": len(result["block"]),
            "defer_count": len(result["defer_ticket_ids"]),
            "drop_count": len(result["drop_defense_records"]),
        },
    }
    _atomic_write_sidecar(
        sidecar_path,
        json.dumps(sidecar_data, indent=2, sort_keys=True),
    )

    return result
