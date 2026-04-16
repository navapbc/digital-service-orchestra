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
import json
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LOG_DIR = Path.home() / ".claude" / "logs"
DISPATCH_LOG_DIR = LOG_DIR  # dispatch-YYYY-MM-DD.jsonl lives alongside tool-use logs
ERROR_COUNTER_FILE = Path.home() / ".claude" / "tool-error-counter.json"
AGENT_PROFILES_DIR = Path(__file__).parent / "agent-profiles"

# Tools that receive pattern analysis (patterns 1-4, 6)
BUILTIN_TOOLS = {
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Glob",
    "Grep",
    "Task",
    "WebSearch",
    "WebFetch",
}

# File-op Bash commands that should use dedicated tools instead
FILE_OP_PATTERNS: list[tuple[str, str]] = [
    # (pattern_to_detect, recommended_tool)
    ("cat ", "Read tool"),
    ("head ", "Read tool (with limit/offset)"),
    ("tail ", "Read tool (with limit/offset)"),
    ("grep ", "Grep tool"),
    ("find ", "Glob tool"),
    ("sed ", "Edit tool"),
    ("awk ", "Edit/Read tool"),
]

# echo redirect patterns (echo "..." > file  or  echo "..." >> file)
ECHO_REDIRECT_RE_FRAGMENTS = [" > ", " >> "]

# Similarity threshold for same-error retry detection
SIMILARITY_THRESHOLD = 0.80

# Search sprawl window (ms) and minimum count
SEARCH_SPRAWL_WINDOW_MS = 120_000  # 2 minutes
SEARCH_SPRAWL_MIN_COUNT = 5

# Redundant call window (ms)
REDUNDANT_WINDOW_MS = 60_000  # 60 seconds

# Lookback windows for suboptimal ordering
ORDERING_LOOKBACK_WRITE_EDIT = 5  # last N calls before Write/Edit
ORDERING_LOOKBACK_COMMIT = 10  # last N calls before git commit
ORDERING_LOOKBACK_PUSH = 20  # last N calls before git push

# Domain mismatch: tools whose file_path reveals agent working domain
FILE_ACCESS_TOOLS = {"Read", "Write", "Edit"}
# Minimum file accesses in a session before mismatch detection applies
DOMAIN_MIN_FILE_ACCESSES = 3
# Fraction threshold: if top domain < this, session is "mixed"
DOMAIN_DOMINANCE_THRESHOLD = 0.60


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------


class LogEntry:
    """A single parsed JSONL log entry."""

    __slots__ = (
        "ts",
        "epoch_ms",
        "session_id",
        "tool_name",
        "hook_type",
        "tool_input_summary",
        "exit_status",
        "raw",
    )

    def __init__(self, data: dict[str, Any]) -> None:
        self.ts: str = data.get("ts", "")
        self.epoch_ms: int = int(data.get("epoch_ms", 0))
        self.session_id: str = data.get("session_id", "")
        self.tool_name: str = data.get("tool_name", "")
        self.hook_type: str = data.get("hook_type", "")
        self.tool_input_summary: str = data.get("tool_input_summary", "")
        self.exit_status: int | None = data.get("exit_status")
        self.raw: dict[str, Any] = data

    def parsed_input(self) -> dict[str, Any]:
        """Try to parse tool_input_summary as JSON; return empty dict on failure."""
        try:
            return json.loads(self.tool_input_summary)
        except (json.JSONDecodeError, TypeError):
            return {}


# ---------------------------------------------------------------------------
# Log file discovery
# ---------------------------------------------------------------------------


def log_files_for_dates(dates: list[date]) -> list[Path]:
    """Return existing log files for the given date list."""
    files: list[Path] = []
    for d in dates:
        path = LOG_DIR / f"tool-use-{d.isoformat()}.jsonl"
        if path.exists():
            files.append(path)
    return files


def all_log_files() -> list[Path]:
    """Return all JSONL log files sorted oldest-first."""
    if not LOG_DIR.exists():
        return []
    return sorted(LOG_DIR.glob("tool-use-*.jsonl"))


def parse_log_file(path: Path) -> list[LogEntry]:
    """Parse a JSONL log file, skipping malformed lines."""
    entries: list[LogEntry] = []
    with path.open(encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                entries.append(LogEntry(data))
            except json.JSONDecodeError:
                print(
                    f"  [warn] {path.name}:{lineno} — malformed JSON, skipping",
                    file=sys.stderr,
                )
    return entries


def load_entries(files: list[Path]) -> list[LogEntry]:
    """Load and return only post-hook entries from all files (sorted by epoch_ms)."""
    all_entries: list[LogEntry] = []
    for f in files:
        all_entries.extend(parse_log_file(f))
    # Filter to post entries only — these represent completed tool calls
    post_entries = [e for e in all_entries if e.hook_type == "post"]
    post_entries.sort(key=lambda e: e.epoch_ms)
    return post_entries


# ---------------------------------------------------------------------------
# Similarity helpers
# ---------------------------------------------------------------------------


def char_similarity(a: str, b: str) -> float:
    """Return Jaccard-style character overlap ratio for short strings."""
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0

    # Use bigrams for a reasonable similarity approximation
    def bigrams(s: str) -> set[str]:
        return {s[i : i + 2] for i in range(len(s) - 1)}

    bg_a = bigrams(a)
    bg_b = bigrams(b)
    if not bg_a and not bg_b:
        return 1.0
    if not bg_a or not bg_b:
        return 0.0
    intersection = len(bg_a & bg_b)
    union = len(bg_a | bg_b)
    return intersection / union


def word_overlap(a: str, b: str) -> float:
    """Return fraction of words in a that also appear in b."""
    words_a = set(a.lower().split())
    words_b = set(b.lower().split())
    if not words_a:
        return 0.0
    return len(words_a & words_b) / len(words_a)


# ---------------------------------------------------------------------------
# Anti-pattern detectors
# ---------------------------------------------------------------------------


def detect_bash_file_ops(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 1: Bash used for file operations instead of dedicated tools."""
    findings: list[dict[str, str]] = []

    for entry in entries:
        if entry.tool_name != "Bash":
            continue

        # Try to extract command from parsed JSON; fall back to raw string search
        parsed = entry.parsed_input()
        command: str = parsed.get("command", "")
        if not command:
            # Fall back: look for "command" in the raw summary string
            summary = entry.tool_input_summary
            try:
                # May be truncated JSON — attempt partial extraction
                idx = summary.find('"command"')
                if idx != -1:
                    rest = summary[idx + len('"command"') :]
                    # Skip past : and optional whitespace/quote
                    colon_idx = rest.find(":")
                    if colon_idx != -1:
                        val_start = rest[colon_idx + 1 :].lstrip()
                        if val_start.startswith('"'):
                            val_start = val_start[1:]
                        # Take until next unescaped quote or end
                        end = val_start.find('"')
                        command = val_start[:end] if end != -1 else val_start[:200]
            except Exception:
                pass

        if not command:
            continue

        # Skip commands that are primarily piping to non-file-op destinations
        # (e.g., grep ... | jq is a data transform, not a file read)
        # We still flag them but note the pipe context.

        already_flagged = False
        for pattern, recommended in FILE_OP_PATTERNS:
            cmd_lower = command.lstrip()
            # Check if command starts with the file-op command or contains it after &&/;/|
            # Simple heuristic: if pattern appears as a standalone command token
            matches = False
            if cmd_lower.startswith(pattern.lstrip()):
                matches = True
            else:
                # Check for the pattern after shell separators
                for sep in (" && ", "; ", " | ", "\n"):
                    for part in command.split(sep):
                        if part.lstrip().startswith(pattern.lstrip()):
                            matches = True
                            break
                    if matches:
                        break

            if matches:
                # Truncate command for display
                display_cmd = command[:120].replace("\n", " ").strip()
                if len(command) > 120:
                    display_cmd += "..."
                findings.append(
                    {
                        "session": entry.session_id,
                        "ts": entry.ts,
                        "command": display_cmd,
                        "recommended": recommended,
                    }
                )
                already_flagged = True
                break  # Only report once per entry

        # Also check for echo redirects (echo "..." > file)
        if not already_flagged:
            has_echo = "echo " in command
            has_redirect = any(frag in command for frag in ECHO_REDIRECT_RE_FRAGMENTS)
            if has_echo and has_redirect:
                display_cmd = command[:120].replace("\n", " ").strip()
                if len(command) > 120:
                    display_cmd += "..."
                findings.append(
                    {
                        "session": entry.session_id,
                        "ts": entry.ts,
                        "command": display_cmd,
                        "recommended": "Write tool",
                    }
                )

    return findings


def detect_write_without_read(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 2: Write tool called on a path never Read in the same session."""
    # Track per session: set of file paths that have been Read
    session_reads: dict[str, set[str]] = defaultdict(set)
    # Track per session: set of file paths first seen as a Write (new file creation)
    session_first_writes: dict[str, set[str]] = defaultdict(set)
    # Track per session: all file paths mentioned at all (for "new file" detection)
    session_seen: dict[str, set[str]] = defaultdict(set)

    findings: list[dict[str, str]] = []

    # Single pass — entries are sorted by epoch_ms
    for entry in entries:
        sid = entry.session_id

        if entry.tool_name == "Read":
            parsed = entry.parsed_input()
            fp = parsed.get("file_path", "")
            if fp:
                session_reads[sid].add(fp)
                session_seen[sid].add(fp)

        elif entry.tool_name == "Write":
            parsed = entry.parsed_input()
            fp = parsed.get("file_path", "")
            if not fp:
                # Try extracting from raw summary
                summary = entry.tool_input_summary
                idx = summary.find('"file_path"')
                if idx != -1:
                    rest = summary[idx + len('"file_path"') :]
                    colon = rest.find(":")
                    if colon != -1:
                        val = rest[colon + 1 :].lstrip()
                        if val.startswith('"'):
                            val = val[1:]
                        end = val.find('"')
                        fp = val[:end] if end != -1 else val[:200]

            if not fp:
                continue

            # If this file path was never seen before, it's a new file creation — skip
            if fp not in session_seen[sid]:
                session_first_writes[sid].add(fp)
                session_seen[sid].add(fp)
                continue

            # File was seen before — was it Read?
            if fp not in session_reads[sid]:
                findings.append(
                    {
                        "session": entry.session_id,
                        "ts": entry.ts,
                        "file_path": fp,
                    }
                )

            session_seen[sid].add(fp)

        else:
            # Track any file paths mentioned in other tools (Edit, Glob results, etc.)
            parsed = entry.parsed_input()
            for key in ("file_path", "path"):
                fp = parsed.get(key, "")
                if fp:
                    session_seen[sid].add(fp)

    return findings


def detect_same_error_retry(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 3: Same tool + similar input retried consecutively after failure."""
    findings: list[dict[str, str]] = []

    # Group by session, maintain a sliding window of recent calls
    session_history: dict[str, list[LogEntry]] = defaultdict(list)

    for entry in entries:
        sid = entry.session_id
        history = session_history[sid]

        if history:
            prev = history[-1]

            # Check if same tool name AND previous call failed
            if prev.tool_name == entry.tool_name and prev.exit_status not in (None, 0):
                sim = char_similarity(
                    prev.tool_input_summary[:300],
                    entry.tool_input_summary[:300],
                )
                if sim >= SIMILARITY_THRESHOLD:
                    # Check if there was an intervening different-tool call
                    # (look at last 3 entries in history for a different tool type)
                    interleaved = any(
                        h.tool_name != entry.tool_name for h in history[-3:]
                    )
                    if not interleaved:
                        cmd_preview = entry.tool_input_summary[:100].replace("\n", " ")
                        findings.append(
                            {
                                "session": entry.session_id,
                                "ts": entry.ts,
                                "tool": entry.tool_name,
                                "similarity": f"{sim:.0%}",
                                "input_preview": cmd_preview,
                            }
                        )

        history.append(entry)
        # Keep history bounded to last 10 entries per session
        if len(history) > 10:
            session_history[sid] = history[-10:]

    return findings


def detect_search_sprawl(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 4: >5 consecutive Glob/Grep calls in 2 minutes with related terms."""
    findings: list[dict[str, str]] = []

    # Group by session
    by_session: dict[str, list[LogEntry]] = defaultdict(list)
    for e in entries:
        if e.tool_name in ("Glob", "Grep"):
            by_session[e.session_id].append(e)

    for sid, session_entries in by_session.items():
        # Sliding window detection
        i = 0
        while i < len(session_entries):
            window_start = session_entries[i].epoch_ms
            window_end = window_start + SEARCH_SPRAWL_WINDOW_MS
            cluster: list[LogEntry] = []

            j = i
            while (
                j < len(session_entries) and session_entries[j].epoch_ms <= window_end
            ):
                cluster.append(session_entries[j])
                j += 1

            if len(cluster) > SEARCH_SPRAWL_MIN_COUNT:
                # Check if search terms are related (share keywords)
                terms: list[str] = []
                for e in cluster:
                    parsed = e.parsed_input()
                    term = (
                        parsed.get("pattern", "")
                        or parsed.get("glob", "")
                        or e.tool_input_summary[:80]
                    )
                    terms.append(term)

                # Only report if terms are related OR cluster is very large
                related = (
                    len(terms) >= 2 and word_overlap(terms[0], terms[-1]) > 0.2
                ) or len(cluster) > SEARCH_SPRAWL_MIN_COUNT + 2

                if related:
                    start_ts = cluster[0].ts
                    end_ts = cluster[-1].ts
                    term_summary = "; ".join(t[:40] for t in terms[:5])
                    if len(terms) > 5:
                        term_summary += f" ... +{len(terms) - 5} more"
                    findings.append(
                        {
                            "session": sid,
                            "start_ts": start_ts,
                            "end_ts": end_ts,
                            "count": str(len(cluster)),
                            "terms_preview": term_summary,
                        }
                    )
                    # Advance past this cluster to avoid double-reporting
                    i = j
                    continue

            i += 1

    return findings


def detect_redundant_calls(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 5: Identical tool_name + tool_input_summary within 60 seconds (all tool types)."""
    findings: list[dict[str, str]] = []

    # Per session: map (tool_name, input_summary) -> last epoch_ms + ts
    session_last: dict[str, dict[tuple[str, str], tuple[int, str]]] = defaultdict(dict)

    for entry in entries:
        sid = entry.session_id
        key = (entry.tool_name, entry.tool_input_summary)
        last = session_last[sid].get(key)

        if last is not None:
            last_epoch, last_ts = last
            if entry.epoch_ms - last_epoch <= REDUNDANT_WINDOW_MS:
                input_preview = entry.tool_input_summary[:100].replace("\n", " ")
                findings.append(
                    {
                        "session": sid,
                        "ts": entry.ts,
                        "tool": entry.tool_name,
                        "first_ts": last_ts,
                        "elapsed_s": f"{(entry.epoch_ms - last_epoch) / 1000:.0f}s",
                        "input_preview": input_preview,
                    }
                )

        session_last[sid][key] = (entry.epoch_ms, entry.ts)

    return findings


def detect_suboptimal_ordering(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 6: Known bad tool sequences."""
    findings: list[dict[str, str]] = []

    # Group entries by session, preserving order
    by_session: dict[str, list[LogEntry]] = defaultdict(list)
    for e in entries:
        by_session[e.session_id].append(e)

    for sid, session_entries in by_session.items():
        for idx, entry in enumerate(session_entries):
            preceding = session_entries[:idx]  # all entries before this one

            # --- 6a: Write/Edit without prior Glob/Read to verify file exists ---
            # Skip when fewer than ORDERING_LOOKBACK_WRITE_EDIT preceding calls
            # (session start) or when Write targets a path not previously seen
            # (new file creation — aligned with Pattern 2's exemption).
            if (
                entry.tool_name in ("Write", "Edit")
                and idx >= ORDERING_LOOKBACK_WRITE_EDIT
            ):
                lookback = preceding[-ORDERING_LOOKBACK_WRITE_EDIT:]
                has_glob_or_read = any(
                    e.tool_name in ("Glob", "Read") for e in lookback
                )
                if not has_glob_or_read:
                    parsed = entry.parsed_input()
                    fp = (
                        parsed.get("file_path", "")
                        or parsed.get("path", "")
                        or "unknown"
                    )
                    # Check if this path was seen before (skip new file creation)
                    seen_paths: set[str] = set()
                    for prev_e in preceding:
                        prev_parsed = prev_e.parsed_input()
                        for key in ("file_path", "path"):
                            p = prev_parsed.get(key, "")
                            if p:
                                seen_paths.add(p)
                    if fp in seen_paths:
                        findings.append(
                            {
                                "session": sid,
                                "ts": entry.ts,
                                "issue": f"{entry.tool_name} without prior Glob/Read",
                                "detail": f"file_path={fp[:80]}",
                            }
                        )

            # --- 6b: git commit without prior git status ---
            elif entry.tool_name == "Bash":
                parsed = entry.parsed_input()
                command = parsed.get("command", "") or entry.tool_input_summary[:200]

                is_commit = "git commit" in command and "--amend" not in command

                if is_commit:
                    lookback = preceding[-ORDERING_LOOKBACK_COMMIT:]
                    has_status = any(
                        "git status"
                        in (e.parsed_input().get("command", "") or e.tool_input_summary)
                        for e in lookback
                        if e.tool_name == "Bash"
                    )
                    if not has_status:
                        findings.append(
                            {
                                "session": sid,
                                "ts": entry.ts,
                                "issue": "git commit without prior git status",
                                "detail": command[:80].replace("\n", " "),
                            }
                        )

                # --- 6c: git push without prior CI check ---
                is_push = "git push" in command

                if is_push:
                    lookback = preceding[-ORDERING_LOOKBACK_PUSH:]

                    def is_ci_check(e: LogEntry) -> bool:
                        c = e.parsed_input().get("command", "") or e.tool_input_summary
                        return any(
                            kw in c
                            for kw in (
                                "ci-status.sh",
                                "make test",
                                "make lint",
                                "pytest",
                                "validate.sh",
                            )
                        )

                    has_ci = any(
                        is_ci_check(e) for e in lookback if e.tool_name == "Bash"
                    )
                    if not has_ci:
                        findings.append(
                            {
                                "session": sid,
                                "ts": entry.ts,
                                "issue": "git push without prior CI check",
                                "detail": command[:80].replace("\n", " "),
                            }
                        )

    return findings


# ---------------------------------------------------------------------------
# Domain mismatch detection (Pattern 7)
# ---------------------------------------------------------------------------


def load_file_patterns(profiles_dir: Path) -> dict[str, list[str]]:
    """Load file_patterns from agent profile YAMLs.

    Returns {agent_type: [pattern, ...]} for profiles with non-empty
    file_patterns.  Profiles with empty lists (domain-agnostic agents)
    are omitted.
    """
    try:
        import yaml  # noqa: PLC0415 — optional dep, same as classify-task.py
    except ImportError:
        return {}

    patterns: dict[str, list[str]] = {}
    for yaml_file in sorted(profiles_dir.glob("*.yaml")):
        if yaml_file.name == "test-cases.yaml":
            continue
        try:
            with open(yaml_file) as f:
                profile = yaml.safe_load(f)
        except Exception:
            continue
        fp = profile.get("file_patterns")
        agent_type = profile.get("agent_type")
        if fp and agent_type:  # non-empty list + valid agent_type
            patterns[agent_type] = fp
    return patterns


def load_dispatch_log(dates: list[date]) -> dict[str, str]:
    """Load dispatch log entries for the given dates.

    Returns {session_id: assigned_agent_type}.
    Dispatch logs live at ~/.claude/logs/dispatch-YYYY-MM-DD.jsonl.
    """
    mapping: dict[str, str] = {}
    for d in dates:
        path = DISPATCH_LOG_DIR / f"dispatch-{d.isoformat()}.jsonl"
        if not path.exists():
            continue
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    sid = entry.get("session_id", "")
                    agent = entry.get("assigned_agent", "")
                    if sid and agent:
                        mapping[sid] = agent
                except (json.JSONDecodeError, TypeError):
                    continue
    return mapping


def _extract_file_path(entry: LogEntry) -> str:
    """Extract file_path from a Read/Write/Edit tool call's input summary."""
    parsed = entry.parsed_input()
    fp = parsed.get("file_path", "")
    if fp:
        return fp
    # Fallback: partial JSON extraction from raw summary
    summary = entry.tool_input_summary
    idx = summary.find('"file_path"')
    if idx == -1:
        return ""
    rest = summary[idx + len('"file_path"') :]
    colon = rest.find(":")
    if colon == -1:
        return ""
    val = rest[colon + 1 :].lstrip()
    if val.startswith('"'):
        val = val[1:]
    end = val.find('"')
    return val[:end] if end != -1 else val[:200]


def score_path_against_patterns(
    file_path: str,
    profile_patterns: dict[str, list[str]],
) -> list[str]:
    """Return all agent_types whose file_patterns match file_path.

    Returns [] if no profile matches.  Multiple profiles may share
    overlapping patterns (e.g. both backend-architect and backend-security
    claim ``src/api/``).  Returning all matches lets the caller decide
    whether a given assignment is acceptable.
    """
    matches: list[str] = []
    for agent_type, patterns in profile_patterns.items():
        for pattern in patterns:
            if pattern in file_path:
                matches.append(agent_type)
                break  # one match per profile is enough
    return matches


def detect_domain_mismatch(
    entries: list[LogEntry],
    profile_patterns: dict[str, list[str]],
    dispatch_map: dict[str, str],
) -> list[dict[str, str]]:
    """Pattern 7: Sub-agent works in a domain different from assignment.

    Two modes:
    - With dispatch log: flag sessions where assigned agent != dominant domain.
    - Without dispatch log: flag sessions with mixed domain access (no clear
      dominant profile accounts for >= DOMAIN_DOMINANCE_THRESHOLD of files).
    """
    findings: list[dict[str, str]] = []

    if not profile_patterns:
        return findings

    # Collect file paths per session
    session_files: dict[str, list[str]] = defaultdict(list)
    for entry in entries:
        if entry.tool_name not in FILE_ACCESS_TOOLS:
            continue
        fp = _extract_file_path(entry)
        if fp:
            session_files[entry.session_id].append(fp)

    for sid, files in session_files.items():
        if len(files) < DOMAIN_MIN_FILE_ACCESSES:
            continue

        # Score each file against profiles.  A file may match multiple
        # profiles (overlapping patterns), so we track both per-profile
        # counts and the full set of profiles each file matched.
        domain_counts: dict[str, int] = defaultdict(int)
        file_match_sets: list[list[str]] = []
        unmatched = 0
        for fp in files:
            matches = score_path_against_patterns(fp, profile_patterns)
            if matches:
                file_match_sets.append(matches)
                for m in matches:
                    domain_counts[m] += 1
            else:
                unmatched += 1

        # Denominator is the number of files that matched at least one
        # profile (not total).  Files outside all known domains (e.g.
        # config, docs) are ignored so they don't dilute the signal.
        matched_file_count = len(file_match_sets)
        if matched_file_count == 0:
            continue  # all files outside any known domain

        # Find dominant domain (profile with most file matches)
        dominant = max(domain_counts, key=domain_counts.get)  # type: ignore[arg-type]
        dominant_frac = domain_counts[dominant] / matched_file_count

        # All profiles that matched ANY file in this session
        all_session_profiles: set[str] = set()
        for ms in file_match_sets:
            all_session_profiles.update(ms)

        assigned = dispatch_map.get(sid)

        if assigned:
            # Mode 1: dispatch log available — check assigned vs actual.
            # Skip if assigned agent is domain-agnostic (not in profile_patterns)
            if assigned not in profile_patterns:
                continue
            # Only flag mismatch if the assigned agent doesn't match ANY
            # file in the session (accounting for overlapping patterns).
            if assigned not in all_session_profiles:
                findings.append(
                    {
                        "session": sid,
                        "assigned": assigned,
                        "actual": dominant,
                        "actual_pct": f"{dominant_frac:.0%}",
                        "file_count": str(len(files)),
                        "distribution": ", ".join(
                            f"{a}: {c}"
                            for a, c in sorted(
                                domain_counts.items(), key=lambda x: -x[1]
                            )
                        ),
                    }
                )
        else:
            # Mode 2: no dispatch log — flag mixed-domain sessions
            if dominant_frac < DOMAIN_DOMINANCE_THRESHOLD and len(domain_counts) > 1:
                findings.append(
                    {
                        "session": sid,
                        "assigned": "(unknown)",
                        "actual": f"mixed ({dominant} {dominant_frac:.0%})",
                        "actual_pct": f"{dominant_frac:.0%}",
                        "file_count": str(len(files)),
                        "distribution": ", ".join(
                            f"{a}: {c}"
                            for a, c in sorted(
                                domain_counts.items(), key=lambda x: -x[1]
                            )
                        ),
                    }
                )

    return findings


# ---------------------------------------------------------------------------
# Cross-reference: error counter
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------


def _session_short(session_id: str) -> str:
    """Return a shortened session ID for display."""
    if len(session_id) > 20:
        return session_id[:8] + "…" + session_id[-6:]
    return session_id


def _render_report_header(
    entries: list[LogEntry],
    files: list[Path],
    total_findings: int,
) -> list[str]:
    """Render the header and summary section of the report."""
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
    lines.append("## Summary")
    lines.append(f"- Total tool calls: {total}")
    lines.append(f"- Unique tools used: {len(tools_used)}")
    lines.append(f"- Anti-patterns detected: {total_findings}")
    lines.append("")
    return lines


def _render_antipattern_findings(
    findings: dict[str, list[dict[str, str]]],
) -> list[str]:
    """Render the anti-pattern findings section of the report."""
    lines: list[str] = []
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

    return lines


def _render_error_and_distribution(
    entries: list[LogEntry],
    error_counts: dict[str, int],
    total_findings: int,
) -> list[str]:
    """Render the cross-reference and tool distribution sections."""
    lines: list[str] = []
    total = len(entries)

    if total_findings == 0:
        lines.append("_No anti-patterns detected._")
        lines.append("")

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

    return lines


def render_report(
    entries: list[LogEntry],
    files: list[Path],
    findings: dict[str, list[dict[str, str]]],
    error_counts: dict[str, int],
) -> str:
    """Render the full Markdown report as a string."""
    total_findings = sum(len(v) for v in findings.values())

    lines: list[str] = []
    lines.extend(_render_report_header(entries, files, total_findings))
    lines.extend(_render_antipattern_findings(findings))
    lines.extend(_render_error_and_distribution(entries, error_counts, total_findings))

    return "\n".join(lines)


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
        # Still emit an empty report
        entries: list[LogEntry] = []
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
        # tool-use-YYYY-MM-DD.jsonl → extract date
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
