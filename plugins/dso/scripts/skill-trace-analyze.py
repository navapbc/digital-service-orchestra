#!/usr/bin/env python3
"""
skill-trace-analyze.py — Analyze DSO skill trace logs for control flow loss patterns.

Reads /tmp/dso-skill-trace-*.log files (or a specific log via --log), detects
CONTROL_LOSS events (SKILL_INVOKE with no matching SKILL_RESUMED), and maps each
session to hypotheses H1-H10.

Usage:
  skill-trace-analyze.py                        # process all /tmp/dso-skill-trace-*.log
  skill-trace-analyze.py --log <path>           # process a specific log file
  skill-trace-analyze.py --all                  # synonym for default (all logs)
  skill-trace-analyze.py --help                 # usage info

Output: JSON array of session diagnostic reports to stdout.
"""

from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TRACE_GLOB = "/tmp/dso-skill-trace-*.log"

# H7: Nesting depth threshold — CONTROL_LOSS at depth >= this is "confirmed"
H7_DEPTH_THRESHOLD = 3

# H1: Tool call count threshold — high tool-call count signals context pressure
H1_TOOL_CALL_THRESHOLD = 60

# H2: Cumulative bytes threshold — large skill file loads signal memory pressure
H2_CUMULATIVE_BYTES_THRESHOLD = 50000

# H3: Elapsed ms threshold — very long-running skills signal timeout risk
H3_ELAPSED_MS_THRESHOLD = 300_000  # 5 minutes

# H4: User interaction count threshold — high interaction in a skill signals confusion
H4_USER_INTERACTION_THRESHOLD = 3

# H5: Ordinal threshold — late-session CONTROL_LOSS signals accumulated context drift
H5_ORDINAL_THRESHOLD = 10

# H6: Skill file size threshold — large child skill size signals prompt overload
H6_SKILL_FILE_SIZE_THRESHOLD = 20_000

# H8: SKILL_ENTER without SKILL_EXIT (child skill never exited)
# H9: Multiple CONTROL_LOSS events in one session
H9_MULTI_CONTROL_LOSS_THRESHOLD = 2

# H10: All invocations are CONTROL_LOSS (every INVOKE lacks RESUMED)


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def parse_log_file(path: Path) -> list[dict[str, Any]]:
    """Read a log file and return a list of parsed breadcrumb dicts.

    Malformed or unparseable lines are silently skipped per spec.
    Returns an empty list if the file does not exist or is empty.
    """
    breadcrumbs: list[dict[str, Any]] = []
    if not path.exists():
        return breadcrumbs
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return breadcrumbs

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                breadcrumbs.append(obj)
        except (json.JSONDecodeError, ValueError):
            # Skip malformed lines per spec
            continue
    return breadcrumbs


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------


def _classify_hypotheses(
    breadcrumbs: list[dict[str, Any]],
    enters: list[dict[str, Any]],
    exits: list[dict[str, Any]],
    invokes: dict[int, dict[str, Any]],
    control_loss_events: list[dict[str, Any]],
    has_control_loss: bool,
) -> dict[str, str]:
    """Classify hypotheses H1-H10 and return a verdict dict."""
    counts = [
        bc.get("tool_call_count")
        for bc in breadcrumbs
        if bc.get("type") == "SKILL_INVOKE" and bc.get("tool_call_count") is not None
    ]
    h1 = (
        ("confirmed" if max(counts) >= H1_TOOL_CALL_THRESHOLD else "refuted")
        if counts and has_control_loss
        else "insufficient-data"
    )
    cum_bytes = [
        bc.get("cumulative_bytes")
        for bc in breadcrumbs
        if bc.get("cumulative_bytes") is not None
    ]
    h2 = (
        ("confirmed" if max(cum_bytes) >= H2_CUMULATIVE_BYTES_THRESHOLD else "refuted")
        if cum_bytes and has_control_loss
        else "insufficient-data"
    )
    elapsed = [bc.get("elapsed_ms") for bc in exits if bc.get("elapsed_ms") is not None]
    h3 = (
        ("confirmed" if max(elapsed) >= H3_ELAPSED_MS_THRESHOLD else "refuted")
        if elapsed and has_control_loss
        else "insufficient-data"
    )
    interactions = [
        bc["user_interaction_count"] for bc in exits if "user_interaction_count" in bc
    ]
    h4 = (
        (
            "confirmed"
            if max(interactions) >= H4_USER_INTERACTION_THRESHOLD
            else "refuted"
        )
        if interactions and has_control_loss
        else "insufficient-data"
    )
    ordinals_at_loss = [
        e["session_ordinal"]
        for e in control_loss_events
        if e["session_ordinal"] is not None
    ]
    h5 = (
        ("confirmed" if max(ordinals_at_loss) >= H5_ORDINAL_THRESHOLD else "refuted")
        if ordinals_at_loss
        else "insufficient-data"
    )
    sizes = [
        bc.get("skill_file_size")
        for bc in breadcrumbs
        if bc.get("skill_file_size") is not None
    ]
    h6 = (
        ("confirmed" if max(sizes) >= H6_SKILL_FILE_SIZE_THRESHOLD else "refuted")
        if sizes and has_control_loss
        else "insufficient-data"
    )
    depths = [
        e["nesting_depth"]
        for e in control_loss_events
        if e.get("nesting_depth") is not None
    ]
    h7 = (
        ("confirmed" if max(depths) >= H7_DEPTH_THRESHOLD else "refuted")
        if depths
        else "insufficient-data"
    )
    enter_ordinals = {
        bc.get("session_ordinal")
        for bc in enters
        if bc.get("session_ordinal") is not None
    }
    exit_ordinals = {
        bc.get("session_ordinal")
        for bc in exits
        if bc.get("session_ordinal") is not None
    }
    h8 = (
        ("confirmed" if (enter_ordinals - exit_ordinals) else "refuted")
        if enters
        else "insufficient-data"
    )
    h9 = (
        (
            "confirmed"
            if len(control_loss_events) >= H9_MULTI_CONTROL_LOSS_THRESHOLD
            else ("refuted" if has_control_loss else "insufficient-data")
        )
        if invokes
        else "insufficient-data"
    )
    h10 = (
        (
            "confirmed"
            if len(control_loss_events) == len(invokes) and has_control_loss
            else ("refuted" if has_control_loss else "insufficient-data")
        )
        if invokes
        else "insufficient-data"
    )
    return {
        "H1": h1,
        "H2": h2,
        "H3": h3,
        "H4": h4,
        "H5": h5,
        "H6": h6,
        "H7": h7,
        "H8": h8,
        "H9": h9,
        "H10": h10,
    }


def analyze_session(
    log_path: Path, breadcrumbs: list[dict[str, Any]]
) -> dict[str, Any]:
    """Analyze breadcrumbs from one session and return a diagnostic report."""
    invokes: dict[int, dict[str, Any]] = {}
    resumed_ordinals: set[int] = set()
    enters: list[dict[str, Any]] = []
    exits: list[dict[str, Any]] = []

    for bc in breadcrumbs:
        bc_type = bc.get("type", "")
        ordinal = bc.get("session_ordinal")
        if bc_type == "SKILL_INVOKE":
            if ordinal is not None and ordinal not in invokes:
                invokes[ordinal] = bc
        elif bc_type == "SKILL_RESUMED":
            if ordinal is not None:
                resumed_ordinals.add(ordinal)
        elif bc_type == "SKILL_ENTER":
            enters.append(bc)
        elif bc_type == "SKILL_EXIT":
            exits.append(bc)

    control_loss_events: list[dict[str, Any]] = [
        {
            "event_type": "CONTROL_LOSS",
            "session_ordinal": ordinal,
            "skill_name": invoke_bc.get("skill_name"),
            "nesting_depth": invoke_bc.get("nesting_depth"),
            "tool_call_count_at_invoke": invoke_bc.get("tool_call_count"),
            "timestamp": invoke_bc.get("timestamp"),
        }
        for ordinal, invoke_bc in sorted(invokes.items())
        if ordinal not in resumed_ordinals
    ]
    has_control_loss = bool(control_loss_events)

    hypotheses = _classify_hypotheses(
        breadcrumbs, enters, exits, invokes, control_loss_events, has_control_loss
    )
    return {
        "session_log": str(log_path),
        "total_breadcrumbs": len(breadcrumbs),
        "total_invocations": len(invokes),
        "total_control_loss": len(control_loss_events),
        "control_loss_events": control_loss_events,
        "hypotheses": hypotheses,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="skill-trace-analyze",
        description="Analyze DSO skill trace logs for CONTROL_LOSS patterns.",
    )
    parser.add_argument(
        "--log",
        metavar="PATH",
        help="Analyze a specific log file instead of all /tmp/dso-skill-trace-*.log files",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Process all /tmp/dso-skill-trace-*.log files (default behavior)",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.log:
        log_paths = [Path(args.log)]
    else:
        # Default: all trace logs, sorted newest first (by mtime descending)
        matched = glob.glob(TRACE_GLOB)
        log_paths = sorted(
            (Path(p) for p in matched),
            key=lambda p: p.stat().st_mtime if p.exists() else 0,
            reverse=True,
        )

    if not log_paths:
        # No logs found — return empty valid JSON
        print("[]")
        return 0

    reports = []
    for log_path in log_paths:
        breadcrumbs = parse_log_file(log_path)
        report = analyze_session(log_path, breadcrumbs)
        reports.append(report)

    print(json.dumps(reports, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
