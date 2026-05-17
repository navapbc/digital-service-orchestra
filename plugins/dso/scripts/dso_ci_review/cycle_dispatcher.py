"""dso_ci_review.cycle_dispatcher — cycle-K next-action decision logic.

Determines whether the review pipeline should PASS, DISPATCH_NEXT cycle,
DISPATCH_ARBITER (at halt boundary), or SHORT_CIRCUIT (re-run on same commit
SHA with existing arbiter ruling). Implements REVIEW-WORKFLOW.md Step 4.75.

Public function:
    next_action(ledger, max_cycles, current_findings, current_commit_sha,
                artifacts_dir=None) -> dict
        Returns {"action": str, "reason": str, "cycle_num": int}

Cycle counter semantics (per AC amendment from gap analysis):
    - Ledger is authoritative source of cycle_num (not DSO_REVIEW_CYCLE env var).
    - If DSO_REVIEW_CYCLE env var disagrees with the ledger (e.g. env says
      cycle=3 but ledger len=1), the ledger wins and a warning is logged.
      This is consistent with Story DD: "ledger is authoritative".
    - When current_commit_sha differs from last cycle's commit_sha -> reset
      cycle_num to 1. The dispatcher returns cycle_num=1 only; the caller is
      responsible for writing a fresh entry on the next append. The dispatcher
      does NOT mutate the ledger.
    - SHORT_CIRCUIT detection: when current SHA matches last cycle's SHA AND
      arbiter-rulings.json exists for that SHA, return SHORT_CIRCUIT (don't
      re-cycle on a CI re-run for the same commit).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from dso_ci_review.stability import should_halt


def _resolve_artifacts_dir(override: str | None) -> str:
    """Use explicit override, else env var, else default location."""
    if override:
        return override
    env = os.environ.get("WORKFLOW_PLUGIN_ARTIFACTS_DIR", "").strip()
    return env or "/tmp"


def _warn_env_vs_ledger_mismatch(ledger_cycle_num: int) -> None:
    """Emit a warning when DSO_REVIEW_CYCLE disagrees with the ledger.

    Ledger wins per Story DD ('ledger is authoritative'). The warning records
    the mismatch so operators can debug CI environments where the env var was
    not refreshed between cycles.
    """
    env_val = os.environ.get("DSO_REVIEW_CYCLE", "").strip()
    if not env_val:
        return
    try:
        env_cycle = int(env_val)
    except ValueError:
        return
    if env_cycle != ledger_cycle_num:
        print(
            f"WARNING: DSO_REVIEW_CYCLE={env_cycle} disagrees with ledger "
            f"cycle_num={ledger_cycle_num}; ledger wins (authoritative)",
            file=sys.stderr,
        )


def next_action(
    ledger: dict,
    max_cycles: int,
    current_findings: list,
    current_commit_sha: str,
    artifacts_dir: str | None = None,
) -> dict:
    """Determine the next pipeline action.

    Args:
        ledger: cycle-ledger.json contents (dict). Corrupt/missing keys treated
            as an empty ledger.
        max_cycles: ceiling at which DISPATCH_ARBITER fires instead of
            DISPATCH_NEXT (when current_findings is non-empty).
        current_findings: unresolved findings for the current cycle (list of
            dicts or 3-tuples consumed by stability.finding_hash).
        current_commit_sha: SHA of the commit under review this cycle.
        artifacts_dir: override location of arbiter-rulings.json for
            SHORT_CIRCUIT detection. Falls back to WORKFLOW_PLUGIN_ARTIFACTS_DIR
            then /tmp.

    Returns:
        dict with keys:
            action: "PASS" | "DISPATCH_NEXT" | "DISPATCH_ARBITER" | "SHORT_CIRCUIT"
            reason: human-readable explanation
            cycle_num: cycle counter the caller should associate with this turn.
                On SHA reset this is 1; on SHORT_CIRCUIT this is the last
                ledger cycle_num (no new cycle is started).
    """
    # Handle corrupt/missing ledger structure (gap-analysis edge case).
    cycles = ledger.get("cycles", []) if isinstance(ledger, dict) else []
    if not isinstance(cycles, list):
        cycles = []

    # Forward-compat: schema_version > 1.1.0 -> warn, best-effort proceed.
    schema_version = (
        ledger.get("schema_version", "1.1.0") if isinstance(ledger, dict) else "1.1.0"
    )
    if schema_version and schema_version > "1.1.0":
        print(
            f"WARNING: cycle-ledger schema_version={schema_version!r} > 1.1.0; "
            "proceeding with best-effort interpretation",
            file=sys.stderr,
        )

    last_cycle = cycles[-1] if cycles else None
    artifacts = _resolve_artifacts_dir(artifacts_dir)

    # Edge case: SHORT_CIRCUIT -- same SHA AND arbiter-rulings.json exists.
    if last_cycle and last_cycle.get("commit_sha") == current_commit_sha:
        arbiter_path = Path(artifacts) / "arbiter-rulings.json"
        if arbiter_path.exists():
            short_cycle_num = last_cycle.get("cycle_num", 1)
            _warn_env_vs_ledger_mismatch(short_cycle_num)
            return {
                "action": "SHORT_CIRCUIT",
                "reason": f"arbiter already ruled on commit {current_commit_sha}",
                "cycle_num": short_cycle_num,
            }

    # Edge case: SHA changed -> reset cycle_num to 1 (wins over max_cycles).
    if (
        last_cycle
        and last_cycle.get("commit_sha")
        and last_cycle["commit_sha"] != current_commit_sha
    ):
        cycle_num = 1
        _warn_env_vs_ledger_mismatch(cycle_num)
        if not current_findings:
            return {
                "action": "PASS",
                "reason": "no unresolved findings (after SHA reset)",
                "cycle_num": cycle_num,
            }
        return {
            "action": "DISPATCH_NEXT",
            "reason": (
                f"commit_sha changed from {last_cycle['commit_sha']!r} to "
                f"{current_commit_sha!r}; reset to cycle 1"
            ),
            "cycle_num": cycle_num,
        }

    # Compute next cycle_num from ledger (ledger is authoritative).
    cycle_num = (
        last_cycle["cycle_num"] + 1
        if last_cycle and "cycle_num" in last_cycle
        else 1
    )
    _warn_env_vs_ledger_mismatch(cycle_num)

    # PASS on no unresolved findings.
    if not current_findings:
        return {
            "action": "PASS",
            "reason": "no unresolved findings",
            "cycle_num": cycle_num,
        }

    # DISPATCH_ARBITER when we have reached max_cycles with unresolved findings.
    if cycle_num >= max_cycles:
        return {
            "action": "DISPATCH_ARBITER",
            "reason": f"cycle_num={cycle_num} >= max_cycles={max_cycles}",
            "cycle_num": cycle_num,
        }

    # Skip Jaccard on cycle 1 (no prior to compare against).
    if not last_cycle or cycle_num == 1:
        return {
            "action": "DISPATCH_NEXT",
            "reason": "first cycle, no prior for Jaccard",
            "cycle_num": cycle_num,
        }

    # Skip Jaccard when prior cycle has reconstruction_gaps -- comparing
    # against partially-reconstructed findings would yield false stability.
    if last_cycle.get("reconstruction_gaps"):
        return {
            "action": "DISPATCH_NEXT",
            "reason": "prior cycle has reconstruction_gaps; skipping Jaccard",
            "cycle_num": cycle_num,
        }

    # STABLE_HALT check via Jaccard similarity.
    prior_findings = last_cycle.get("findings", [])
    halt, signal = should_halt(current_findings, prior_findings, threshold=0.85)
    if halt:
        # Halt only matters if there are unresolved critical/important findings.
        # When findings are non-dict (tuples), severity is unknown -- treat as
        # significant per the contract (caller normalized to dicts in practice).
        has_critical_important = any(
            isinstance(f, dict) and f.get("severity") in ("critical", "important")
            for f in current_findings
        )
        all_non_dict = current_findings and not any(
            isinstance(f, dict) for f in current_findings
        )
        if has_critical_important or all_non_dict:
            return {
                "action": "DISPATCH_ARBITER",
                "reason": (
                    f"{signal}: Jaccard >= 0.85 with unresolved "
                    "critical/important findings"
                ),
                "cycle_num": cycle_num,
            }

    # Default: below halt threshold and below max_cycles.
    return {
        "action": "DISPATCH_NEXT",
        "reason": "below halt threshold, below max_cycles",
        "cycle_num": cycle_num,
    }
