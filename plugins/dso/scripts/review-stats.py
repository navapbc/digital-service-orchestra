#!/usr/bin/env python3
"""Review stats aggregation and reporting module.

Reads JSONL review event files, compacts fragments, computes metrics,
and formats summary tables for terminal output.

CLI: python3 review-stats.py [--since=YYYY-MM-DD] [--all] [--events-dir=DIR]
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------


def read_events(path: Path) -> list[dict]:
    """Read a JSONL file and return a list of parsed event dicts.

    Skips malformed lines (invalid JSON) and lines missing the
    ``event_type`` field.  Warnings are logged for each skipped line.
    """
    events: list[dict] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                logger.warning(
                    "Skipping malformed JSON at %s:%d",
                    path,
                    lineno,
                )
                continue

            if not isinstance(record, dict) or "event_type" not in record:
                logger.warning(
                    "Skipping line missing 'event_type' at %s:%d",
                    path,
                    lineno,
                )
                continue

            events.append(record)
    return events


def read_events_dir(events_dir: Path, since: str | None = None) -> list[dict]:
    """Read all ``.jsonl`` files in *events_dir*.

    If *since* is an ISO-8601 date string (``YYYY-MM-DD``), only events
    whose ``timestamp`` falls on or after that date are included.
    """
    all_events: list[dict] = []
    if not events_dir.is_dir():
        return all_events

    for jsonl_file in sorted(events_dir.glob("*.jsonl")):
        all_events.extend(read_events(jsonl_file))

    if since is not None:
        cutoff = datetime.fromisoformat(since).replace(tzinfo=timezone.utc)
        all_events = [
            e
            for e in all_events
            if datetime.fromisoformat(e.get("timestamp", "1970-01-01T00:00:00Z"))
            >= cutoff
        ]
    return all_events


def filter_by_time_window(events: list[dict], days: int) -> list[dict]:
    """Return events whose ``timestamp`` is within *days* of now."""
    cutoff = datetime.now(tz=timezone.utc) - timedelta(days=days)
    result: list[dict] = []
    for event in events:
        ts_str = event.get("timestamp")
        if ts_str is None:
            continue
        try:
            ts = datetime.fromisoformat(ts_str)
        except (ValueError, TypeError):
            continue
        if ts > cutoff:
            result.append(event)
    return result


# ---------------------------------------------------------------------------
# Compaction
# ---------------------------------------------------------------------------


def compact_fragments(events_dir: Path) -> None:
    """Merge per-agent fragment JSONL files into date-partitioned files.

    Fragments are files whose names do **not** match ``YYYY-MM-DD.jsonl``.
    Events are bucketed by date and appended to the corresponding
    ``YYYY-MM-DD.jsonl`` file.  Fragment files are deleted after merging.

    The operation is idempotent — running it twice produces no duplicates
    because fragment files are removed after their contents are merged.

    Uses ``flock`` on ``.review-events/.review-compact.lock`` when
    available.
    """
    import fcntl
    import re

    date_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")
    lock_path = events_dir / ".review-compact.lock"

    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)

        fragments: list[Path] = []
        for f in sorted(events_dir.glob("*.jsonl")):
            if not date_pattern.match(f.name):
                fragments.append(f)

        if not fragments:
            return

        # Bucket events by date
        buckets: dict[str, list[str]] = defaultdict(list)
        for frag in fragments:
            with open(frag, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    ts = record.get("timestamp", "")
                    try:
                        dt = datetime.fromisoformat(ts)
                        date_key = dt.strftime("%Y-%m-%d")
                    except (ValueError, TypeError):
                        date_key = "unknown"
                    buckets[date_key].append(line)

        # Append to date-partitioned files
        for date_key, lines in buckets.items():
            target = events_dir / f"{date_key}.jsonl"
            with open(target, "a", encoding="utf-8") as fh:
                for raw_line in lines:
                    fh.write(raw_line + "\n")

        # Remove fragments
        for frag in fragments:
            frag.unlink(missing_ok=True)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ---------------------------------------------------------------------------
# Metrics computation
# ---------------------------------------------------------------------------


def compute_pass_fail_rates(events: list[dict]) -> dict:
    """Compute pass/fail rates from review_result events.

    Looks at the ``pass_fail`` field (``"passed"`` / ``"failed"``).
    Returns ``{pass_rate: float, fail_rate: float, total: int}``.
    """
    total = len(events)
    if total == 0:
        return {"pass_rate": 0.0, "fail_rate": 0.0, "total": 0}

    passed = sum(1 for e in events if e.get("pass_fail") == "passed")
    failed = total - passed
    return {
        "pass_rate": (passed / total) * 100.0,
        "fail_rate": (failed / total) * 100.0,
        "total": total,
    }


def compute_avg_dimension_scores(events: list[dict]) -> dict[str, float]:
    """Average dimension scores across events.

    Each event is expected to have a ``dimension_scores`` dict mapping
    dimension names to numeric scores.
    """
    totals: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)

    for event in events:
        dims = event.get("dimension_scores", {})
        if not isinstance(dims, dict):
            continue
        for dim, score in dims.items():
            try:
                totals[dim] += float(score)
                counts[dim] += 1
            except (ValueError, TypeError):
                continue

    return {dim: totals[dim] / counts[dim] for dim in totals if counts[dim] > 0}


def compute_finding_severity_distribution(events: list[dict]) -> dict[str, int]:
    """Count findings by severity across all events.

    Each event may have a ``findings`` list of dicts, each with a
    ``severity`` key.
    """
    dist: dict[str, int] = defaultdict(int)
    for event in events:
        findings = event.get("findings", [])
        if not isinstance(findings, list):
            continue
        for finding in findings:
            sev = finding.get("severity", "unknown")
            dist[sev] += 1
    return dict(dist)


def compute_metrics(events: list[dict]) -> dict:
    """Compute all metrics from a list of events.

    Returns a dict with keys: pass_fail, dimension_scores,
    severity_distribution, revision_cycles, commit_stats, session_ids.
    """
    review_events = [e for e in events if e.get("event_type") == "review_result"]
    commit_events = [e for e in events if e.get("event_type") == "commit_workflow"]

    # Pass/fail rates
    pass_fail = compute_pass_fail_rates(review_events)

    # Dimension scores
    dimension_scores = compute_avg_dimension_scores(review_events)

    # Severity distribution
    severity_dist = compute_finding_severity_distribution(review_events)

    # Avg revision cycles
    resolution_attempts = [
        e.get("resolution_attempts", 0)
        for e in review_events
        if "resolution_attempts" in e
    ]
    avg_revision_cycles = (
        sum(resolution_attempts) / len(resolution_attempts)
        if resolution_attempts
        else 0.0
    )

    # Commit stats
    total_commits = len(commit_events)
    committed = sum(1 for e in commit_events if e.get("outcome") == "committed")
    blocked = total_commits - committed
    commit_failure_rate = (
        (blocked / total_commits * 100.0) if total_commits > 0 else 0.0
    )

    # Session IDs (for traceability)
    session_ids = [e.get("session_id") for e in events if e.get("session_id")]

    return {
        "pass_fail": pass_fail,
        "dimension_scores": dimension_scores,
        "severity_distribution": severity_dist,
        "avg_revision_cycles": avg_revision_cycles,
        "commit_stats": {
            "total": total_commits,
            "committed": committed,
            "blocked": blocked,
            "failure_rate": commit_failure_rate,
        },
        "session_ids": session_ids,
    }


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------


def format_table(metrics: dict) -> str:
    """Format metrics as an aligned terminal summary table."""
    lines: list[str] = []

    # Pass/fail
    pf = metrics.get("pass_fail", {})
    lines.append("Review Pass/Fail")
    lines.append(f"  Total reviews:  {pf.get('total', 0)}")
    lines.append(f"  Pass rate:      {pf.get('pass_rate', 0.0):.1f}%")
    lines.append(f"  Fail rate:      {pf.get('fail_rate', 0.0):.1f}%")
    lines.append("")

    # Dimension scores
    dims = metrics.get("dimension_scores", {})
    if dims:
        lines.append("Average Dimension Scores")
        max_key_len = max(len(k) for k in dims)
        for dim, score in sorted(dims.items()):
            lines.append(f"  {dim:<{max_key_len}}  {score:.1f}")
        lines.append("")

    # Severity distribution
    sev = metrics.get("severity_distribution", {})
    if sev:
        lines.append("Finding Severity Distribution")
        for severity, count in sorted(sev.items()):
            lines.append(f"  {severity:<12}  {count}")
        lines.append("")

    # Revision cycles
    lines.append(f"Avg Revision Cycles: {metrics.get('avg_revision_cycles', 0.0):.1f}")
    lines.append("")

    # Commit stats
    cs = metrics.get("commit_stats", {})
    lines.append("Commit Workflow")
    lines.append(f"  Total attempts: {cs.get('total', 0)}")
    lines.append(f"  Committed:      {cs.get('committed', 0)}")
    lines.append(f"  Blocked:        {cs.get('blocked', 0)}")
    lines.append(f"  Failure rate:   {cs.get('failure_rate', 0.0):.1f}%")

    # Session IDs
    session_ids = metrics.get("session_ids", [])
    if session_ids:
        lines.append("")
        lines.append("Sessions Included")
        for sid in session_ids:
            lines.append(f"  {sid}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Review stats aggregation and reporting.",
    )
    parser.add_argument(
        "--since",
        metavar="YYYY-MM-DD",
        default=None,
        help="Include events from this date onward (default: last 30 days).",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        dest="show_all",
        help="Include all events (ignore time window).",
    )
    parser.add_argument(
        "--events-dir",
        type=Path,
        default=None,
        help="Path to events directory (default: .review-events/ in repo root).",
    )
    args = parser.parse_args()

    if args.events_dir:
        events_dir = args.events_dir
    else:
        try:
            import subprocess

            repo_root = subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"],
                text=True,
            ).strip()
            events_dir = Path(repo_root) / ".review-events"
        except Exception:
            events_dir = Path(".review-events")

    if not events_dir.is_dir():
        print(f"Events directory not found: {events_dir}", file=sys.stderr)
        sys.exit(1)

    # Determine time filter
    since: str | None = None
    if args.show_all:
        since = None
    elif args.since:
        since = args.since
    else:
        # Default 30-day window
        cutoff = datetime.now(tz=timezone.utc) - timedelta(days=30)
        since = cutoff.strftime("%Y-%m-%d")

    events = read_events_dir(events_dir, since=since)

    if not events:
        print("No events found in the specified time window.")
        sys.exit(0)

    metrics = compute_metrics(events)
    print(format_table(metrics))


if __name__ == "__main__":
    main()
