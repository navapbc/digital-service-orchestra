"""Report rendering for analyze-tool-use."""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from analyze_tool._constants import ERROR_COUNTER_FILE
from analyze_tool._models import LogEntry


def _session_short(session_id: str) -> str:
    """Return a shortened session ID for display."""
    if len(session_id) > 20:
        return session_id[:8] + "…" + session_id[-6:]
    return session_id


def load_error_counter() -> dict[str, int]:
    """Load category counts from ~/.claude/tool-error-counter.json."""
    if not ERROR_COUNTER_FILE.exists():
        return {}
    try:
        data = json.loads(ERROR_COUNTER_FILE.read_text(encoding="utf-8"))
        index = data.get("index", {})
        return {k: int(v) for k, v in index.items()}
    except (json.JSONDecodeError, TypeError, KeyError):
        return {}


def _render_findings(
    lines: list[str], findings: dict[str, list[dict[str, str]]]
) -> None:
    """Append anti-pattern finding sections to lines (mutates in place)."""
    lines.append("## Anti-Pattern Findings")
    lines.append("")

    bash_ops = findings.get("bash_file_ops", [])
    if bash_ops:
        lines.append(f"### 1. Bash-for-file-ops ({len(bash_ops)} occurrences)")
        lines.append("")
        lines.append("| Session | Timestamp | Bash Command | Recommended Alternative |")
        lines.append("|---------|-----------|-------------|------------------------|")
        for f in bash_ops:
            lines.append(
                f"| {_session_short(f['session'])} "
                f"| {f['ts']} "
                f"| `{f['command']}` "
                f"| {f['recommended']} |"
            )
        lines.append("")

    blind_writes = findings.get("write_without_read", [])
    if blind_writes:
        lines.append(f"### 2. Write-without-Read ({len(blind_writes)} occurrences)")
        lines.append("")
        lines.append("| Session | Timestamp | File Path |")
        lines.append("|---------|-----------|-----------|")
        for f in blind_writes:
            lines.append(
                f"| {_session_short(f['session'])} | {f['ts']} | `{f['file_path']}` |"
            )
        lines.append("")

    retries = findings.get("same_error_retry", [])
    if retries:
        lines.append(f"### 3. Same-error retry ({len(retries)} occurrences)")
        lines.append("")
        lines.append("| Session | Timestamp | Tool | Similarity | Input Preview |")
        lines.append("|---------|-----------|------|-----------|---------------|")
        for f in retries:
            lines.append(
                f"| {_session_short(f['session'])} "
                f"| {f['ts']} "
                f"| {f['tool']} "
                f"| {f['similarity']} "
                f"| `{f['input_preview']}` |"
            )
        lines.append("")

    sprawl = findings.get("search_sprawl", [])
    if sprawl:
        lines.append(f"### 4. Sequential search sprawl ({len(sprawl)} occurrences)")
        lines.append("")
        lines.append("| Session | Start | End | Count | Terms Preview |")
        lines.append("|---------|-------|-----|-------|---------------|")
        for f in sprawl:
            lines.append(
                f"| {_session_short(f['session'])} "
                f"| {f['start_ts']} "
                f"| {f['end_ts']} "
                f"| {f['count']} "
                f"| {f['terms_preview']} |"
            )
        lines.append("")

    redundant = findings.get("redundant_calls", [])
    if redundant:
        lines.append(f"### 5. Redundant tool calls ({len(redundant)} occurrences)")
        lines.append("")
        lines.append(
            "| Session | Timestamp | Tool | First Call | Elapsed | Input Preview |"
        )
        lines.append(
            "|---------|-----------|------|-----------|---------|---------------|"
        )
        for f in redundant:
            lines.append(
                f"| {_session_short(f['session'])} "
                f"| {f['ts']} "
                f"| {f['tool']} "
                f"| {f['first_ts']} "
                f"| {f['elapsed_s']} "
                f"| `{f['input_preview']}` |"
            )
        lines.append("")

    ordering = findings.get("suboptimal_ordering", [])
    if ordering:
        lines.append(f"### 6. Suboptimal tool ordering ({len(ordering)} occurrences)")
        lines.append("")
        lines.append("| Session | Timestamp | Issue | Detail |")
        lines.append("|---------|-----------|-------|--------|")
        for f in ordering:
            lines.append(
                f"| {_session_short(f['session'])} "
                f"| {f['ts']} "
                f"| {f['issue']} "
                f"| `{f['detail']}` |"
            )
        lines.append("")

    mismatches = findings.get("domain_mismatch", [])
    if mismatches:
        lines.append(f"### 7. Domain mismatch ({len(mismatches)} occurrences)")
        lines.append("")
        lines.append("| Session | Assigned | Actual Domain | Files | Distribution |")
        lines.append("|---------|----------|---------------|-------|--------------|")
        for f in mismatches:
            lines.append(
                f"| {_session_short(f['session'])} "
                f"| {f['assigned']} "
                f"| {f['actual']} "
                f"| {f['file_count']} "
                f"| {f['distribution']} |"
            )
        lines.append("")

    if sum(len(v) for v in findings.values()) == 0:
        lines.append("_No anti-patterns detected._")
        lines.append("")


def render_report(
    entries: list[LogEntry],
    files: list[Path],
    findings: dict[str, list[dict[str, str]]],
    error_counts: dict[str, int],
) -> str:
    """Render the full Markdown report as a string."""
    lines: list[str] = []

    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sessions = {e.session_id for e in entries}
    total = len(entries)
    tools_used = {e.tool_name for e in entries}

    if entries:
        ts_list = [e.ts for e in entries if e.ts]
        date_start = min(ts_list) if ts_list else "?"
        date_end = max(ts_list) if ts_list else "?"
    else:
        date_start = date_end = "?"

    lines.append("# Tool-Use Analysis Report")
    lines.append(f"Generated: {now}")
    lines.append(
        f"Sessions analyzed: {len(sessions)} | Date range: {date_start} - {date_end}"
    )
    lines.append(f"Log files read: {len(files)}")
    lines.append("")

    total_findings = sum(len(v) for v in findings.values())
    lines.append("## Summary")
    lines.append(f"- Total tool calls: {total}")
    lines.append(f"- Unique tools used: {len(tools_used)}")
    lines.append(f"- Anti-patterns detected: {total_findings}")
    lines.append("")

    _render_findings(lines, findings)

    lines.append("## Cross-Reference: Error Patterns")
    if error_counts:
        lines.append(f"(from `{ERROR_COUNTER_FILE}`)")
        lines.append("")
        lines.append("| Category | Count |")
        lines.append("|----------|-------|")
        for cat, count in sorted(error_counts.items(), key=lambda x: -x[1]):
            lines.append(f"| {cat} | {count} |")
    else:
        lines.append(f"_No data found at `{ERROR_COUNTER_FILE}`._")
    lines.append("")

    lines.append("## Tool Distribution")
    if entries:
        tool_counts: dict[str, int] = defaultdict(int)
        for e in entries:
            tool_counts[e.tool_name] += 1
        sorted_tools = sorted(tool_counts.items(), key=lambda x: -x[1])
        lines.append("| Tool | Calls | % |")
        lines.append("|------|-------|---|")
        for tool, count in sorted_tools:
            pct = count / total * 100
            lines.append(f"| {tool} | {count} | {pct:.1f}% |")
    else:
        lines.append("_No tool calls recorded._")
    lines.append("")

    return "\n".join(lines)
