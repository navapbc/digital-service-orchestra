"""Log file discovery and parsing for analyze-tool-use."""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path

from analyze_tool._constants import LOG_DIR
from analyze_tool._models import LogEntry


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
