#!/usr/bin/env python3
"""
analyze-tool-use.py — Detect anti-patterns in Claude Code tool-use JSONL logs.

Reads ~/.claude/logs/tool-use-YYYY-MM-DD.jsonl and reports 6 anti-patterns that
complement (do not overlap with) error tracking in track-tool-errors.sh and
track-cascade-failures.sh.

Anti-patterns detected:
  1. Bash-for-file-ops: Using Bash cat/grep/find/etc. instead of Read/Grep/Glob/Edit/Write
  2. Write-without-Read: Write tool called on a path not previously Read in the session
  3. Same-error retry: Same tool + similar input retried consecutively without strategy change
  4. Sequential search sprawl: >5 Glob/Grep calls in 2 minutes with related terms
  5. Redundant tool calls: Identical tool + input within 60 seconds
  6. Suboptimal tool ordering: Bad sequences like Write before Glob, commit before status
  7. Domain mismatch: Sub-agent assigned to one domain but file activity in another

Usage:
  python scripts/analyze-tool-use.py              # today's logs
  python scripts/analyze-tool-use.py --days=7     # last 7 days
  python scripts/analyze-tool-use.py --date=2026-02-21  # specific date
  python scripts/analyze-tool-use.py --all        # all available logs
  python scripts/analyze-tool-use.py --help       # usage info
"""

from __future__ import annotations

import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Submodule imports — all logic lives in analyze_tool/
# ---------------------------------------------------------------------------

# Ensure the scripts directory is on the path so analyze_tool package is importable
_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from analyze_tool._constants import AGENT_PROFILES_DIR, BUILTIN_TOOLS, LOG_DIR  # noqa: E402
from analyze_tool._detectors import (  # noqa: E402
    detect_bash_file_ops,
    detect_domain_mismatch,
    detect_redundant_calls,
    detect_same_error_retry,
    detect_search_sprawl,
    detect_suboptimal_ordering,
    detect_write_without_read,
    load_dispatch_log,
    load_file_patterns,
)
from analyze_tool._log_io import all_log_files, load_entries, log_files_for_dates  # noqa: E402
from analyze_tool._report import load_error_counter, render_report  # noqa: E402

# Re-export public symbols for backward compatibility
__all__ = [
    "detect_bash_file_ops",
    "detect_domain_mismatch",
    "detect_redundant_calls",
    "detect_same_error_retry",
    "detect_search_sprawl",
    "detect_suboptimal_ordering",
    "detect_write_without_read",
    "load_dispatch_log",
    "load_file_patterns",
    "all_log_files",
    "load_entries",
    "log_files_for_dates",
    "load_error_counter",
    "render_report",
]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="analyze-tool-use.py",
        description=(
            "Detect anti-patterns in Claude Code tool-use JSONL logs. "
            "Complements track-tool-errors.sh and track-cascade-failures.sh."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python scripts/analyze-tool-use.py              # today's logs\n"
            "  python scripts/analyze-tool-use.py --days=7     # last 7 days\n"
            "  python scripts/analyze-tool-use.py --date=2026-02-21  # specific date\n"
            "  python scripts/analyze-tool-use.py --all        # all available logs\n"
        ),
    )

    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--days",
        type=int,
        metavar="N",
        help="Analyze logs from the last N days (default: today only)",
    )
    group.add_argument(
        "--date",
        type=str,
        metavar="YYYY-MM-DD",
        help="Analyze logs for a specific date",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Analyze all available log files",
    )

    return parser.parse_args()


def resolve_files(args: argparse.Namespace) -> list[Path]:
    """Determine which log files to process based on CLI args."""
    today = date.today()

    if args.all:
        return all_log_files()

    if args.date:
        try:
            target = date.fromisoformat(args.date)
        except ValueError:
            print(
                f"Error: invalid date '{args.date}'. Use YYYY-MM-DD format.",
                file=sys.stderr,
            )
            sys.exit(1)
        return log_files_for_dates([target])

    if args.days:
        dates = [today - timedelta(days=i) for i in range(args.days)]
        return log_files_for_dates(dates)

    # Default: today
    return log_files_for_dates([today])


def main() -> None:
    args = parse_args()
    files = resolve_files(args)

    if not files:
        print("No log files found. Is tool logging enabled?", file=sys.stderr)
        print(
            f"  Expected location: {LOG_DIR}/tool-use-YYYY-MM-DD.jsonl", file=sys.stderr
        )
        print("  Enable with: scripts/toggle-tool-logging.sh", file=sys.stderr)
        entries = []
    else:
        entries = load_entries(files)

    if not entries:
        print(
            "No post-hook entries found. Run some tool calls with logging enabled first.",
            file=sys.stderr,
        )

    # Filter to built-in tools for patterns 1-4, 6
    builtin_entries = [e for e in entries if e.tool_name in BUILTIN_TOOLS]

    # Load agent profile file_patterns for domain mismatch detection
    profile_patterns = load_file_patterns(AGENT_PROFILES_DIR)

    # Derive dates from resolved log files for dispatch log lookup
    log_dates: list[date] = []
    for f in files:
        stem = f.stem  # "tool-use-2026-02-24"
        parts = stem.split("tool-use-")
        if len(parts) == 2:
            try:
                log_dates.append(date.fromisoformat(parts[1]))
            except ValueError:
                pass

    dispatch_map = load_dispatch_log(log_dates) if log_dates else {}

    # Run all detectors
    findings: dict[str, list[dict[str, str]]] = {
        "bash_file_ops": detect_bash_file_ops(builtin_entries),
        "write_without_read": detect_write_without_read(builtin_entries),
        "same_error_retry": detect_same_error_retry(builtin_entries),
        "search_sprawl": detect_search_sprawl(builtin_entries),
        # Pattern 5 uses ALL entries (including MCP tools)
        "redundant_calls": detect_redundant_calls(entries),
        "suboptimal_ordering": detect_suboptimal_ordering(builtin_entries),
        # Pattern 7 uses ALL entries (file access spans all tool types)
        "domain_mismatch": detect_domain_mismatch(
            entries,
            profile_patterns,
            dispatch_map,
        ),
    }

    error_counts = load_error_counter()

    report = render_report(entries, files, findings, error_counts)
    print(report)


if __name__ == "__main__":
    main()
