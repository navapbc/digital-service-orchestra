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


def compute_review_caught_bugs(events: list[dict]) -> int:
    """Count review-caught bugs not caught by tests using compound heuristic.

    A finding is counted when ALL four criteria are met:
    1. test_gate_status == "passed" (tests were green, so tests missed this)
    2. dimension is "correctness" or "verification" (substantive bug dimensions)
    3. severity is critical, major, important, or severe
    4. resolution is "code-change" (not a defense/dismissal)
    """
    qualifying_severities = {"critical", "major", "important", "severe"}
    qualifying_dimensions = {"correctness", "verification"}
    count = 0

    for event in events:
        if event.get("test_gate_status") != "passed":
            continue
        findings = event.get("findings", [])
        if not isinstance(findings, list):
            continue
        for finding in findings:
            if (
                finding.get("dimension") in qualifying_dimensions
                and finding.get("severity") in qualifying_severities
                and finding.get("resolution") == "code-change"
            ):
                count += 1

    return count


def compute_tier_distribution(events: list[dict]) -> dict[str, int]:
    """Count review events by tier (light, standard, deep)."""
    dist: dict[str, int] = defaultdict(int)
    for event in events:
        tier = event.get("tier", "unknown")
        dist[tier] += 1
    return dict(dist)


def compute_overlay_counts(events: list[dict]) -> dict[str, int]:
    """Count how many events triggered each overlay type."""
    counts: dict[str, int] = defaultdict(int)
    for event in events:
        overlays = event.get("overlays", [])
        if not isinstance(overlays, list):
            continue
        for overlay in overlays:
            counts[overlay] += 1
    return dict(counts)


def compute_escalation_count(events: list[dict]) -> int:
    """Count events where escalation occurred."""
    return sum(1 for e in events if e.get("escalated") is True)


def compute_metrics(events: list[dict]) -> dict:
    """Compute all metrics from a list of events.

    Returns a dict with keys: pass_fail, dimension_scores,
    severity_distribution, revision_cycles, commit_stats, session_ids,
    review_caught_bugs, tier_distribution, overlay_counts,
    escalation_count.
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
    committed_events = [e for e in commit_events if e.get("outcome") == "committed"]
    committed = len(committed_events)
    blocked = total_commits - committed
    commit_failure_rate = (
        (blocked / total_commits * 100.0) if total_commits > 0 else 0.0
    )

    # Avg commit duration (from committed events with duration_ms)
    durations = [e["duration_ms"] for e in committed_events if "duration_ms" in e]
    avg_duration_ms = sum(durations) / len(durations) if durations else 0.0

    # Session IDs (for traceability)
    session_ids = [e.get("session_id") for e in events if e.get("session_id")]

    # Compound heuristic: review-caught bugs not caught by tests
    review_caught_bugs = compute_review_caught_bugs(review_events)

    # Tier usage distribution
    tier_distribution = compute_tier_distribution(review_events)

    # Overlay trigger counts
    overlay_counts = compute_overlay_counts(review_events)

    # Escalation frequency
    escalation_count = compute_escalation_count(review_events)

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
            "avg_duration_ms": avg_duration_ms,
        },
        "session_ids": session_ids,
        "review_caught_bugs": review_caught_bugs,
        "tier_distribution": tier_distribution,
        "overlay_counts": overlay_counts,
        "escalation_count": escalation_count,
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
    lines.append(f"  Avg duration:   {cs.get('avg_duration_ms', 0.0):.0f}ms")

    # Review-caught bugs (compound heuristic)
    review_caught = metrics.get("review_caught_bugs", 0)
    lines.append("")
    lines.append(f"Review-Caught Bugs (not caught by tests): {review_caught}")

    # Tier distribution
    tier_dist = metrics.get("tier_distribution", {})
    if tier_dist:
        lines.append("")
        lines.append("Tier Usage Distribution")
        for tier, count in sorted(tier_dist.items()):
            lines.append(f"  {tier:<12}  {count}")

    # Escalation frequency
    escalation_count = metrics.get("escalation_count", 0)
    lines.append("")
    lines.append(f"Escalation Count: {escalation_count}")

    # Overlay trigger counts
    overlay_counts = metrics.get("overlay_counts", {})
    if overlay_counts:
        lines.append("")
        lines.append("Overlay Trigger Counts")
        for overlay, count in sorted(overlay_counts.items()):
            lines.append(f"  {overlay:<16}  {count}")

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


def _resolve_events_dir(events_dir_arg: Path | None) -> Path:
    """Resolve the events directory from arg or repo root detection."""
    if events_dir_arg:
        return events_dir_arg
    try:
        import subprocess

        repo_root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
        ).strip()
        return Path(repo_root) / ".review-events"
    except Exception:
        return Path(".review-events")


def format_metrics_table(events_all: list[dict]) -> str:
    """Compute and format the 4 advanced metrics over 7-day and 30-day windows.

    # ---------------------------------------------------------------------------
    # PLAYBOOK — Advanced Metrics Interpretation
    # ---------------------------------------------------------------------------
    # phantom_escalation_rate > 0.3 for 2 consecutive 7-day windows:
    #   -> Open a P2 bug against the cycle-1 severity rubric. The classifier
    #      is over-escalating; tighten the escalation threshold or audit the
    #      rubric for over-broad severity definitions.
    #
    # prior_region_resustain_skew > 3.0 for 2 consecutive windows:
    #   -> Investigate proximity-overlap false positives. A high skew means
    #      resustains are clustering inside prior regions, suggesting the
    #      overlap detection window is too wide and creating phantom hits.
    # ---------------------------------------------------------------------------
    """
    windows = {
        "7d": filter_by_time_window(events_all, 7),
        "30d": filter_by_time_window(events_all, 30),
    }

    rows = [
        ("p90_cycle_count", compute_p90_cycle_count, "{:.1f}"),
        ("phantom_escalation_rate", compute_phantom_escalation_rate, "{:.3f}"),
        ("call2_finding_drop_rate", compute_call2_finding_drop_rate, "{:.3f}"),
        ("prior_region_resustain_skew", compute_prior_region_resustain_skew, "{:.3f}"),
    ]

    col_metric = max(len(r[0]) for r in rows)
    lines: list[str] = []
    lines.append(f"{'Metric':<{col_metric}}  {'7-day':>8}  {'30-day':>8}")
    lines.append("-" * (col_metric + 20))
    for name, fn, fmt in rows:
        v7 = fn(windows["7d"])
        v30 = fn(windows["30d"])
        lines.append(f"{name:<{col_metric}}  {fmt.format(v7):>8}  {fmt.format(v30):>8}")
    return "\n".join(lines)


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
    parser.add_argument(
        "--metrics",
        action="store_true",
        help=(
            "Compute and print advanced metrics (p90_cycle_count, "
            "phantom_escalation_rate, call2_finding_drop_rate, "
            "prior_region_resustain_skew) over rolling 7-day and 30-day windows."
        ),
    )
    args = parser.parse_args()

    events_dir = _resolve_events_dir(args.events_dir)

    if args.metrics:
        # For --metrics, an absent events dir is not fatal — show zero values.
        events_all: list[dict] = []
        if events_dir.is_dir():
            events_all = read_events_dir(events_dir, since=None)
        print(format_metrics_table(events_all))
        sys.exit(0)

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


def compute_p90_cycle_count(events: list[dict]) -> float:
    """Return 90th-percentile cycle_count across all events.

    Uses the exclusive (Type 6 / Minitab) percentile method:
    virtual index = (N + 1) * 0.9 - 1, with linear interpolation.
    """
    values = [e["cycle_count"] for e in events if "cycle_count" in e]
    if not values:
        return 0.0
    values.sort()
    n = len(values)
    idx = (n + 1) * 0.9 - 1
    if idx <= 0:
        return float(values[0])
    if idx >= n - 1:
        return float(values[-1])
    lo = int(idx)
    frac = idx - lo
    return values[lo] + frac * (values[lo + 1] - values[lo])


def compute_phantom_escalation_rate(events: list[dict]) -> float:
    """Return fraction of escalated events that were phantom escalations."""
    escalated = [e for e in events if e.get("escalated")]
    if not escalated:
        return 0.0
    phantom = sum(1 for e in escalated if e.get("phantom_escalation"))
    return phantom / len(escalated)


def compute_prior_region_resustain_skew(events: list[dict]) -> float:
    """Return ratio of in-prior-region resustains to out-of-region resustains."""
    resustains = [e for e in events if e.get("event_type") == "resustain"]
    in_region = sum(1 for e in resustains if e.get("in_prior_region"))
    out_region = sum(1 for e in resustains if not e.get("in_prior_region"))
    if out_region == 0:
        return 0.0
    return in_region / out_region


def compute_call2_finding_drop_rate(events: list[dict]) -> float:
    """Return fraction of Call 1 findings absent in Call 2 output."""
    total_call1 = sum(e.get("call1_finding_count", 0) for e in events)
    total_call2 = sum(e.get("call2_finding_count", 0) for e in events)
    if total_call1 == 0:
        return 0.0
    dropped = total_call1 - total_call2
    return dropped / total_call1


if __name__ == "__main__":
    main()
