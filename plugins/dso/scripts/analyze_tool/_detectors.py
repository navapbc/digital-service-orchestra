"""Anti-pattern detectors for analyze-tool-use."""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import date
from pathlib import Path

from analyze_tool._constants import (
    DISPATCH_LOG_DIR,
    DOMAIN_DOMINANCE_THRESHOLD,
    DOMAIN_MIN_FILE_ACCESSES,
    ECHO_REDIRECT_RE_FRAGMENTS,
    FILE_ACCESS_TOOLS,
    FILE_OP_PATTERNS,
    ORDERING_LOOKBACK_COMMIT,
    ORDERING_LOOKBACK_PUSH,
    ORDERING_LOOKBACK_WRITE_EDIT,
    REDUNDANT_WINDOW_MS,
    SEARCH_SPRAWL_MIN_COUNT,
    SEARCH_SPRAWL_WINDOW_MS,
    SIMILARITY_THRESHOLD,
)
from analyze_tool._models import LogEntry
from analyze_tool._similarity import char_similarity, word_overlap


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

        already_flagged = False
        for pattern, recommended in FILE_OP_PATTERNS:
            cmd_lower = command.lstrip()
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
    session_reads: dict[str, set[str]] = defaultdict(set)
    session_first_writes: dict[str, set[str]] = defaultdict(set)
    session_seen: dict[str, set[str]] = defaultdict(set)

    findings: list[dict[str, str]] = []

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

            if fp not in session_seen[sid]:
                session_first_writes[sid].add(fp)
                session_seen[sid].add(fp)
                continue

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

    session_history: dict[str, list[LogEntry]] = defaultdict(list)

    for entry in entries:
        sid = entry.session_id
        history = session_history[sid]

        if history:
            prev = history[-1]

            if prev.tool_name == entry.tool_name and prev.exit_status not in (None, 0):
                sim = char_similarity(
                    prev.tool_input_summary[:300],
                    entry.tool_input_summary[:300],
                )
                if sim >= SIMILARITY_THRESHOLD:
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
        if len(history) > 10:
            session_history[sid] = history[-10:]

    return findings


def detect_search_sprawl(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 4: >5 consecutive Glob/Grep calls in 2 minutes with related terms."""
    findings: list[dict[str, str]] = []

    by_session: dict[str, list[LogEntry]] = defaultdict(list)
    for e in entries:
        if e.tool_name in ("Glob", "Grep"):
            by_session[e.session_id].append(e)

    for sid, session_entries in by_session.items():
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
                terms: list[str] = []
                for e in cluster:
                    parsed = e.parsed_input()
                    term = (
                        parsed.get("pattern", "")
                        or parsed.get("glob", "")
                        or e.tool_input_summary[:80]
                    )
                    terms.append(term)

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
                    i = j
                    continue

            i += 1

    return findings


def detect_redundant_calls(
    entries: list[LogEntry],
) -> list[dict[str, str]]:
    """Pattern 5: Identical tool_name + tool_input_summary within 60 seconds (all tool types)."""
    findings: list[dict[str, str]] = []

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

    by_session: dict[str, list[LogEntry]] = defaultdict(list)
    for e in entries:
        by_session[e.session_id].append(e)

    for sid, session_entries in by_session.items():
        for idx, entry in enumerate(session_entries):
            preceding = session_entries[:idx]

            # --- 6a: Write/Edit without prior Glob/Read to verify file exists ---
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
    """Return all agent_types whose file_patterns match file_path."""
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
    """Pattern 7: Sub-agent works in a domain different from assignment."""
    findings: list[dict[str, str]] = []

    if not profile_patterns:
        return findings

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

        matched_file_count = len(file_match_sets)
        if matched_file_count == 0:
            continue

        dominant = max(domain_counts, key=domain_counts.get)  # type: ignore[arg-type]
        dominant_frac = domain_counts[dominant] / matched_file_count

        all_session_profiles: set[str] = set()
        for ms in file_match_sets:
            all_session_profiles.update(ms)

        assigned = dispatch_map.get(sid)

        if assigned:
            if assigned not in profile_patterns:
                continue
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
