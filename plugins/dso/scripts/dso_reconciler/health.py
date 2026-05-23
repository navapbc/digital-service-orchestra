"""Health record module for the DSO reconciler.

Writes structured JSON health records after each reconciler pass so operators
can track fsck totals, per-type open counts, and mutation volume over time.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

SCHEMA_VERSION = 1


def record_pass(
    pass_id: str,
    pre_fsck: int,
    post_fsck: int,
    per_type_counts: dict,
    local_mutation_count: int,
    repo_root: Path | None = None,
) -> Path:
    """Write a health record for a completed reconciler pass.

    Args:
        pass_id: Unique identifier for this reconciler pass.
        pre_fsck: Bridge fsck total before the pass.
        post_fsck: Bridge fsck total after the pass.
        per_type_counts: Open count per ticket type (e.g. {epic, story, task, bug}).
        local_mutation_count: Number of mutations applied during this pass.
        repo_root: Repository root path. Defaults to four levels above this
            file (resolved at runtime via ``Path(__file__).parents[4]``).

    Returns:
        Path to the written JSON health record file.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]  # four levels up from dso_reconciler/
    health_dir = repo_root / "bridge_state" / "health"
    health_dir.mkdir(parents=True, exist_ok=True)
    record = {
        "schema_version": SCHEMA_VERSION,
        "pass_id": pass_id,
        "pre_pass_fsck_total": pre_fsck,
        "post_pass_fsck_total": post_fsck,
        "per_type_open_counts": per_type_counts,
        "local_mutation_count_at_pass": local_mutation_count,
        "timestamp_ns": time.time_ns(),
    }
    out_path = health_dir / f"{pass_id}.json"
    out_path.write_text(json.dumps(record, indent=2))
    return out_path


def capture_baseline(pass_id: str, repo_root: Path | None = None) -> Path:
    """Capture pre-pass fsck total from the current ticket store state.

    Reads the current open ticket count from the ticket store by inspecting
    the latest STATUS event for each ticket directory. Stores the result as a
    baseline snapshot so the reconciler can compare post-pass totals.

    Args:
        pass_id: Unique identifier for this reconciler pass.
        repo_root: Repository root path. Defaults to four levels above this
            file (resolved at runtime via ``Path(__file__).parents[4]``).

    Returns:
        Path to the written JSON baseline file.
    """
    if repo_root is None:
        repo_root = Path(__file__).parents[4]  # repo root from dso_reconciler/

    # Count total open tickets across all types as the baseline fsck total.
    tickets_dir = repo_root / ".tickets-tracker"  # tickets-boundary-ok
    total_open = 0
    if tickets_dir.is_dir():
        for ticket_dir in tickets_dir.iterdir():
            if not ticket_dir.is_dir():
                continue
            # Find the most recent STATUS event for this ticket.
            event_files = sorted(ticket_dir.glob("*.json"))
            latest_status = None
            for ef in event_files:
                try:
                    data = json.loads(ef.read_text())
                    if data.get("event_type") == "STATUS":
                        latest_status = data.get("status", "")
                except Exception:  # noqa: BLE001
                    continue
            if latest_status == "open":
                total_open += 1

    health_dir = repo_root / "bridge_state" / "health"
    health_dir.mkdir(parents=True, exist_ok=True)
    baseline = {
        "pass_id": pass_id,
        "pre_pass_fsck_total": total_open,
        "timestamp_ns": time.time_ns(),
    }
    out_path = health_dir / f"{pass_id}_baseline.json"
    out_path.write_text(json.dumps(baseline, indent=2))
    return out_path
