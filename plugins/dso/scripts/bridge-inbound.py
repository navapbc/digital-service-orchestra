#!/usr/bin/env python3
"""Inbound bridge: pull Jira changes into local ticket system.

Fetches Jira issues via windowed JQL pull, normalizes timestamps to UTC epoch,
and writes CREATE event files for new Jira-originated tickets.

No external dependencies — uses importlib, json, os, pathlib, time, uuid, datetime, re.
"""

from __future__ import annotations

import importlib.util
import json
import re
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from types import ModuleType
from typing import Any


# ---------------------------------------------------------------------------
# Module loading helpers
# ---------------------------------------------------------------------------


def _load_module_from_path(name: str, path: Path) -> ModuleType:
    """Load a Python module from a filesystem path via importlib."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        msg = f"Cannot load module from {path}"
        raise ImportError(msg)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


# ---------------------------------------------------------------------------
# Timestamp helpers
# ---------------------------------------------------------------------------

# Jira ISO 8601 format with milliseconds and timezone offset (no colon)
# e.g. "2026-03-21T10:00:00.000+0530" or "2026-03-21T10:00:00.000+0000"
_JIRA_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?"
    r"([+-]\d{2}:?\d{2}|Z)$"
)


def _parse_jira_timestamp(ts_str: str) -> datetime:
    """Parse a Jira ISO 8601 timestamp string to a timezone-aware datetime.

    Handles formats like:
        2026-03-21T10:00:00.000+0530
        2026-03-21T10:00:00.000+00:00
        2026-03-21T10:00:00Z
    """
    m = _JIRA_TS_RE.match(ts_str)
    if not m:
        # Fallback: try stdlib fromisoformat directly
        return datetime.fromisoformat(ts_str)

    base = m.group(1)
    tz_part = m.group(2)

    if tz_part == "Z":
        tz_part = "+00:00"
    elif len(tz_part) == 5 and ":" not in tz_part:
        # Convert +0530 -> +05:30
        tz_part = tz_part[:3] + ":" + tz_part[3:]

    iso_str = f"{base}{tz_part}"
    return datetime.fromisoformat(iso_str)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def fetch_jira_changes(
    acli_client: Any,
    *,
    last_pull_ts: str,
    overlap_buffer_minutes: int,
    project: str | None = None,
) -> list[dict[str, Any]]:
    """Fetch Jira issues updated since last_pull_ts minus overlap_buffer_minutes.

    Args:
        acli_client: Object with search_issues(jql, start_at, max_results) method.
        last_pull_ts: UTC ISO 8601 timestamp string of last pull.
        overlap_buffer_minutes: Minutes to subtract for overlap buffer.
        project: Optional Jira project key to filter by.

    Returns:
        Flat list of Jira issue dicts.
    """
    # Parse the last pull timestamp and subtract the overlap buffer
    dt = datetime.fromisoformat(last_pull_ts.replace("Z", "+00:00"))
    buffered_dt = dt - timedelta(minutes=overlap_buffer_minutes)

    # Format as Jira JQL datetime string (UTC)
    buffered_ts_str = buffered_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    # Build JQL — sanitize project to block JQL injection
    jql = f'updatedDate >= "{buffered_ts_str}"'
    if project:
        # Strip or reject characters that could break out of the JQL string context
        # (quotes, backslashes, and JQL operator characters).
        _SAFE_PROJECT_RE = re.compile(r'["\\\[\]{}()|&;,]')
        sanitized_project = _SAFE_PROJECT_RE.sub("", project).strip()
        if not sanitized_project:
            msg = f"project key is empty after sanitization: {project!r}"
            raise ValueError(msg)
        jql = f'project = "{sanitized_project}" AND {jql}'

    # Single-page fetch (full pagination added in T4)
    results = acli_client.search_issues(jql, start_at=0, max_results=100)
    if not results:
        return []

    return list(results)


def normalize_timestamps(issue: dict[str, Any]) -> dict[str, Any]:
    """Convert Jira timestamp fields to UTC epoch ints.

    For each of created, updated, resolutiondate in issue["fields"]:
    parse ISO 8601 string and convert to UTC epoch int via .timestamp().
    Fields absent or None are left unchanged.

    Args:
        issue: Jira issue dict with a "fields" sub-dict.

    Returns:
        The modified issue dict (in-place modification).
    """
    fields = issue.get("fields")
    if fields is None:
        return issue

    ts_field_names = ("created", "updated", "resolutiondate")

    for field_name in ts_field_names:
        if field_name not in fields:
            continue
        value = fields[field_name]
        if value is None:
            continue
        if isinstance(value, str):
            dt = _parse_jira_timestamp(value)
            fields[field_name] = int(dt.timestamp())

    return issue


def write_create_events(
    issues: list[dict[str, Any]],
    *,
    tickets_tracker: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> list[Path]:
    """Write CREATE event files for new Jira-originated tickets.

    For each Jira issue, checks if any ticket directory already has a SYNC event
    referencing this Jira key (idempotency guard). If not, generates a local
    ticket ID and writes a CREATE event file.

    Args:
        issues: List of Jira issue dicts (each must have "key" and "fields").
        tickets_tracker: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        run_id: Run ID for traceability.

    Returns:
        List of Paths to CREATE event files that were written.
    """
    written: list[Path] = []

    # Build set of Jira keys that already have SYNC events (idempotency)
    synced_jira_keys: set[str] = set()
    if tickets_tracker.is_dir():
        for sync_file in tickets_tracker.rglob("*-SYNC.json"):
            try:
                sync_data = json.loads(sync_file.read_text(encoding="utf-8"))
                jira_key = sync_data.get("jira_key", "")
                if jira_key:
                    synced_jira_keys.add(jira_key)
            except (OSError, json.JSONDecodeError):
                continue

    for issue in issues:
        jira_key = issue.get("key", "")
        if not jira_key:
            continue

        # Idempotency guard: skip if SYNC event already exists for this key
        if jira_key in synced_jira_keys:
            continue

        # Normalize timestamps on a copy of the issue
        normalized_issue = normalize_timestamps(
            json.loads(json.dumps(issue))  # deep copy via JSON round-trip
        )

        # Generate local ticket ID: jira-<key_lowercase>
        local_id = f"jira-{jira_key.lower()}"

        # Create ticket directory
        ticket_dir = tickets_tracker / local_id
        ticket_dir.mkdir(parents=True, exist_ok=True)

        # Write CREATE event file
        ts = int(time.time())
        event_uuid = str(uuid.uuid4())
        filename = f"{ts}-{event_uuid}-CREATE.json"

        normalized_fields = normalized_issue.get("fields", {})

        payload: dict[str, Any] = {
            "event_type": "CREATE",
            "env_id": bridge_env_id,
            "jira_key": jira_key,
            "local_id": local_id,
            "timestamp": ts,
            "run_id": run_id,
            "data": {
                "jira_key": jira_key,
                "fields": normalized_fields,
            },
        }

        event_path = ticket_dir / filename
        event_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        written.append(event_path)

    return written
