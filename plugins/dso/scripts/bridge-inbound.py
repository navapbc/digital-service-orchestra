#!/usr/bin/env python3
"""Inbound bridge: pull Jira changes into local ticket system.

Fetches Jira issues via windowed JQL pull, normalizes timestamps to UTC epoch,
and writes CREATE event files for new Jira-originated tickets.

No external dependencies — uses importlib, json, os, pathlib, time, uuid, datetime, re.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import tempfile
import time
import uuid
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from types import ModuleType
from typing import Any

# Ensure the scripts directory is on sys.path so that `from bridge import ...`
# works when this module is loaded via importlib (e.g., in tests).
_SCRIPTS_DIR = str(Path(__file__).resolve().parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Jira priority name → local 0-4 integer scale (used by both CREATE and EDIT paths)
_JIRA_PRIORITY_TO_LOCAL: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}


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
# Checkpoint helpers
# ---------------------------------------------------------------------------


def _atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    """Write JSON data to *path* atomically via os.replace (POSIX-atomic rename)."""
    dir_path = path.parent
    dir_path.mkdir(parents=True, exist_ok=True)
    fd, tmp_path_str = tempfile.mkstemp(dir=str(dir_path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp_path_str, str(path))
    except BaseException:
        # Clean up temp file on failure
        try:
            os.unlink(tmp_path_str)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def fetch_jira_changes(
    acli_client: Any,
    *,
    last_pull_ts: str,
    overlap_buffer_minutes: int,
    project: str | None = None,
    on_batch_complete: Callable[[int], None] | None = None,
    start_at_override: int | None = None,
) -> list[dict[str, Any]]:
    """Fetch Jira issues updated since last_pull_ts minus overlap_buffer_minutes.

    Args:
        acli_client: Object with search_issues(jql, start_at, max_results) method.
        last_pull_ts: UTC ISO 8601 timestamp string of last pull.
        overlap_buffer_minutes: Minutes to subtract for overlap buffer.
        project: Optional Jira project key to filter by.
        on_batch_complete: Optional callback invoked after each page with
            the next start_at cursor value (start_at + len(page)).
        start_at_override: Optional starting offset for resume support.

    Returns:
        Flat list of Jira issue dicts.
    """
    # Parse the last pull timestamp and subtract the overlap buffer
    dt = datetime.fromisoformat(last_pull_ts.replace("Z", "+00:00"))
    buffered_dt = dt - timedelta(minutes=overlap_buffer_minutes)

    # Format as Jira JQL datetime string — Jira accepts 'yyyy-mm-dd HH:mm'
    # (space separator, no seconds, no timezone suffix).
    buffered_ts_str = buffered_dt.strftime("%Y-%m-%d %H:%M")

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

    # Paginated fetch — loop until a page returns empty or fewer than max_results
    all_results: list[dict[str, Any]] = []
    start_at = start_at_override if start_at_override is not None else 0
    max_results = 100

    while True:
        page = acli_client.search_issues(
            jql, start_at=start_at, max_results=max_results
        )
        if not page:
            break
        all_results.extend(page)
        start_at += len(page)
        if on_batch_complete is not None:
            on_batch_complete(start_at)
        if len(page) < max_results:
            break

    return all_results


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

        # Map Jira fields to local ticket schema so the reducer can
        # read ticket_type, title, priority, and assignee from data.*
        # (the reducer requires data.ticket_type and data.title).
        jira_issuetype = normalized_fields.get("issuetype", {})
        jira_type_name = (
            jira_issuetype.get("name", "Task")
            if isinstance(jira_issuetype, dict)
            else "Task"
        )
        jira_summary = normalized_fields.get("summary", "")
        # Empty description safeguard: store None instead of empty string
        # to prevent overwriting a non-empty local description later.
        _raw_desc = normalized_fields.get("description", "")
        jira_description = (
            _raw_desc if isinstance(_raw_desc, str) and _raw_desc.strip() else None
        )

        # Map Jira priority to local 0-4 integer scale
        jira_priority_obj = normalized_fields.get("priority", {})
        local_priority: int | None = None
        if isinstance(jira_priority_obj, dict):
            pname = jira_priority_obj.get("name", "")
            local_priority = _JIRA_PRIORITY_TO_LOCAL.get(pname)

        # Map Jira assignee to local string
        jira_assignee_obj = normalized_fields.get("assignee", {})
        local_assignee: str | None = None
        if isinstance(jira_assignee_obj, dict):
            local_assignee = jira_assignee_obj.get(
                "displayName", jira_assignee_obj.get("emailAddress")
            )

        payload: dict[str, Any] = {
            "event_type": "CREATE",
            "env_id": bridge_env_id,
            "jira_key": jira_key,
            "local_id": local_id,
            "timestamp": ts,
            "run_id": run_id,
            "data": {
                "jira_key": jira_key,
                "ticket_type": jira_type_name.lower(),
                "title": jira_summary,
                "description": jira_description,
                "priority": local_priority,
                "assignee": local_assignee,
                "fields": normalized_fields,
            },
        }

        event_path = ticket_dir / filename
        event_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        written.append(event_path)

    return written


# ---------------------------------------------------------------------------
# Destructive change guards
# ---------------------------------------------------------------------------

# Type hierarchy: lower index = higher rank.  Types not listed are unranked (rank=999).
_TYPE_HIERARCHY = ["epic", "story", "task", "chore", "bug"]


def is_destructive_change(existing: dict[str, Any], inbound: dict[str, Any]) -> bool:
    """Return True if *inbound* would destructively overwrite *existing* data.

    Destructive cases:
      - Replacing a non-empty description with an empty/whitespace-only string
      - Removing relationships (existing has links, inbound has fewer or none)
      - Downgrading ticket type (e.g. epic -> task)
    """
    # 1. Empty-over-non-empty description
    existing_desc = existing.get("description", "").strip()
    inbound_desc = inbound.get("description", "").strip()
    if existing_desc and not inbound_desc:
        return True

    # 2. Relationship removal
    existing_links = existing.get("links", [])
    inbound_links = inbound.get("links", [])
    if existing_links and len(inbound_links) < len(existing_links):
        return True

    # 3. Type downgrade
    existing_type = existing.get("type", "")
    inbound_type = inbound.get("type", "")
    if existing_type and inbound_type and existing_type != inbound_type:
        existing_rank = (
            _TYPE_HIERARCHY.index(existing_type)
            if existing_type in _TYPE_HIERARCHY
            else 999
        )
        inbound_rank = (
            _TYPE_HIERARCHY.index(inbound_type)
            if inbound_type in _TYPE_HIERARCHY
            else 999
        )
        if inbound_rank > existing_rank:
            return True

    return False


def map_status(jira_status: str, *, mapping: dict[str, str]) -> str | None:
    """Look up jira_status in mapping dict; return local status or None if unmapped."""
    return mapping.get(jira_status)


def map_type(jira_type: str, *, mapping: dict[str, str]) -> str | None:
    """Look up jira_type in mapping dict; return local type or None if unmapped."""
    return mapping.get(jira_type)


def write_status_event(
    *,
    ticket_id: str,
    status: str,
    ticket_dir: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> Path:
    """Write a bridge-authored STATUS event file for a Jira status change.

    Creates a STATUS event file at <ticket_dir>/<ts>-<uuid>-STATUS.json,
    enabling bidirectional flap detection by recording status transitions
    that originate from the inbound bridge.

    Args:
        ticket_id: Local ticket ID.
        status: The new local status value (already mapped from Jira).
        ticket_dir: Path to the ticket directory.
        bridge_env_id: UUID of this bridge environment.
        run_id: Run ID for traceability.

    Returns:
        Path to the written STATUS event file.
    """
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ts = int(time.time())
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-STATUS.json"

    payload: dict[str, Any] = {
        "event_type": "STATUS",
        "env_id": bridge_env_id,
        "timestamp": ts,
        "uuid": event_uuid,
        "data": {"status": status},
    }
    if run_id:
        payload["run_id"] = run_id

    event_path = ticket_dir / filename
    event_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return event_path


def persist_relationship_rejection(
    *,
    ticket_id: str,
    ticket_dir: Path,
    reason: str,
) -> Path:
    """Write a .jira-sync-status file recording a Jira relationship rejection.

    When Jira rejects a relationship push, this records the rejection locally
    without modifying the local relationship. The local ticket's links/deps
    are NEVER removed — only the status file is written.

    Args:
        ticket_id: Local ticket ID.
        ticket_dir: Path to the ticket directory.
        reason: Human-readable reason for the rejection.

    Returns:
        Path to the written .jira-sync-status file.
    """
    ticket_dir.mkdir(parents=True, exist_ok=True)

    sync_status: dict[str, Any] = {
        "jira_sync_status": "rejected",
        "reason": reason,
    }

    status_path = ticket_dir / ".jira-sync-status"
    _atomic_write_json(status_path, sync_status)
    return status_path


def write_edit_event(
    *,
    ticket_id: str,
    fields: dict[str, Any],
    ticket_dir: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> Path:
    """Write a bridge-authored EDIT event file for Jira field changes.

    Args:
        ticket_id: Local ticket ID.
        fields: Dict of field_name → new_value to update.
        ticket_dir: Path to the ticket directory.
        bridge_env_id: UUID of this bridge environment.
        run_id: Run ID for traceability.

    Returns:
        Path to the written EDIT event file.
    """
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ts = int(time.time())
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-EDIT.json"

    payload: dict[str, Any] = {
        "event_type": "EDIT",
        "env_id": bridge_env_id,
        "timestamp": ts,
        "uuid": event_uuid,
        "data": {"fields": fields},
    }
    if run_id:
        payload["run_id"] = run_id

    event_path = ticket_dir / filename
    event_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return event_path


def write_bridge_alert(
    *,
    ticket_id: str,
    reason: str,
    tickets_root: Path,
    bridge_env_id: str,
) -> Path:
    """Write a BRIDGE_ALERT event file for unmapped status/type values.

    Args:
        ticket_id: Local ticket ID.
        reason: Human-readable reason for the alert.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.

    Returns:
        Path to the written BRIDGE_ALERT event file.
    """
    ticket_dir = tickets_root / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ts = int(time.time())
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-BRIDGE_ALERT.json"

    payload: dict[str, Any] = {
        "event_type": "BRIDGE_ALERT",
        "reason": reason,
        "env_id": bridge_env_id,
        "timestamp": ts,
    }

    event_path = ticket_dir / filename
    event_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return event_path


def verify_jira_timezone_utc(acli_client: Any) -> bool:
    """Check that the Jira server's service account timezone is UTC.

    Args:
        acli_client: Object with get_server_info() method.

    Returns:
        True if timezone is UTC, False otherwise.
    """
    import logging

    server_info = acli_client.get_server_info()
    tz = server_info.get("timeZone", "")
    if tz == "UTC":
        return True

    logging.warning("Jira service account timezone is '%s', expected 'UTC'", tz)
    return False


def _fetch_issues_with_checkpoint(
    acli_client: Any,
    *,
    last_pull_ts: str,
    config: dict[str, Any],
) -> list[dict[str, Any]]:
    """Fetch Jira issues, supporting batched resume via checkpoint cursor.

    Builds the per-batch cursor callback from config and calls
    fetch_jira_changes. Raises CalledProcessError on auth failure (401).

    Args:
        acli_client: ACLI client object.
        last_pull_ts: UTC ISO 8601 timestamp of last successful pull.
        config: process_inbound config dict.

    Returns:
        List of Jira issue dicts.
    """
    import logging
    import subprocess

    checkpoint_file = config.get("checkpoint_file", "")
    overlap_buffer_minutes = config.get("overlap_buffer_minutes", 15)
    resume = config.get("resume", False)
    batch_resume_cursor = config.get("batch_resume_cursor")
    project = config.get("project") or None

    def _save_batch_cursor(cursor: int) -> None:
        if checkpoint_file:
            cp_path = Path(checkpoint_file)
            current: dict[str, Any] = {}
            if cp_path.exists():
                try:
                    current = json.loads(cp_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    pass
            current["batch_resume_cursor"] = cursor
            _atomic_write_json(cp_path, current)

    start_at_override: int | None = None
    if resume and batch_resume_cursor is not None:
        start_at_override = int(batch_resume_cursor)

    try:
        return fetch_jira_changes(
            acli_client,
            last_pull_ts=last_pull_ts,
            overlap_buffer_minutes=overlap_buffer_minutes,
            project=project,
            on_batch_complete=_save_batch_cursor,
            start_at_override=start_at_override,
        )
    except subprocess.CalledProcessError as exc:
        if exc.returncode == 401:
            logging.error("Authentication failure (401) — checkpoint NOT updated")
        raise


def _write_success_checkpoint(
    checkpoint_file: str,
    run_id: str,
) -> None:
    """Advance last_pull_ts in the checkpoint file on full-run success.

    Clears batch_resume_cursor (no stale cursor left behind). Only writes
    when checkpoint_file is non-empty.

    Args:
        checkpoint_file: Path string for the checkpoint JSON file.
        run_id: Run ID for traceability (written as last_run_id).
    """
    if not checkpoint_file:
        return
    from datetime import timezone

    new_ts = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    checkpoint_data: dict[str, Any] = {"last_pull_ts": new_ts}
    if run_id:
        checkpoint_data["last_run_id"] = run_id
    # batch_resume_cursor intentionally omitted — cleared on success
    _atomic_write_json(Path(checkpoint_file), checkpoint_data)


def _process_single_issue(
    issue: dict[str, Any],
    *,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str,
    status_mapping: dict[str, str],
    type_mapping: dict[str, str],
    ticket_reducer: Any,
    acli_client: Any,
    unmapped_type_keys: set[str],
) -> None:
    """Dispatch a single normalized Jira issue through all event handlers.

    Handlers are called in order: destructive guard → status → edit →
    type check → links. Each handler that signals a skip causes an early
    return; the type check also mutates unmapped_type_keys.

    Args:
        issue: Normalized Jira issue dict.
        tickets_root: Path to the .tickets-tracker directory.
        bridge_env_id: UUID of this bridge environment.
        run_id: Run ID for traceability.
        status_mapping: Jira status → local status mapping.
        type_mapping: Jira type → local type mapping.
        ticket_reducer: Pre-loaded ticket-reducer module (or None).
        acli_client: ACLI client object.
        unmapped_type_keys: Mutable set accumulating unmapped Jira keys.
    """
    from bridge import (
        check_destructive_guard,
        handle_edit,
        handle_links,
        handle_status,
        handle_type_check,
    )

    if check_destructive_guard(
        issue,
        tickets_root=tickets_root,
        bridge_env_id=bridge_env_id,
        type_mapping=type_mapping,
        is_destructive_change_fn=is_destructive_change,
        map_type_fn=map_type,
        write_bridge_alert_fn=write_bridge_alert,
    ):
        return

    handle_status(
        issue,
        tickets_root=tickets_root,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
        status_mapping=status_mapping,
        map_status_fn=map_status,
        write_bridge_alert_fn=write_bridge_alert,
        write_status_event_fn=write_status_event,
    )
    handle_edit(
        issue,
        tickets_root=tickets_root,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
        ticket_reducer=ticket_reducer,
        write_edit_event_fn=write_edit_event,
    )

    if handle_type_check(
        issue,
        tickets_root=tickets_root,
        bridge_env_id=bridge_env_id,
        type_mapping=type_mapping,
        unmapped_type_keys=unmapped_type_keys,
        map_type_fn=map_type,
        write_bridge_alert_fn=write_bridge_alert,
    ):
        return

    handle_links(
        issue,
        tickets_root=tickets_root,
        bridge_env_id=bridge_env_id,
        acli_client=acli_client,
        persist_relationship_rejection_fn=persist_relationship_rejection,
        write_bridge_alert_fn=write_bridge_alert,
    )


def process_inbound(
    *,
    tickets_root: Path,
    acli_client: Any,
    last_pull_ts: str,
    config: dict[str, Any],
) -> None:
    """Orchestrator entry point for inbound bridge sync.

    Args:
        tickets_root: Path to the .tickets-tracker directory.
        acli_client: ACLI client object.
        last_pull_ts: UTC ISO 8601 timestamp of last successful pull.
        config: Configuration dict with keys:
            - bridge_env_id (str)
            - overlap_buffer_minutes (int, default 15)
            - checkpoint_file (str): path to checkpoint JSON file
            - status_mapping (dict)
            - type_mapping (dict)
            - run_id (str, optional)
    """
    import logging

    # UTC health check — halt if not UTC
    if not verify_jira_timezone_utc(acli_client):
        msg = "Jira service account timezone is not UTC — aborting inbound sync"
        logging.error(msg)
        raise RuntimeError(msg)

    bridge_env_id = config.get("bridge_env_id", "")
    status_mapping = config.get("status_mapping", {})
    type_mapping = config.get("type_mapping", {})
    checkpoint_file = config.get("checkpoint_file", "")
    run_id = config.get("run_id", "")

    issues = _fetch_issues_with_checkpoint(
        acli_client, last_pull_ts=last_pull_ts, config=config
    )

    reducer_path = Path(__file__).resolve().parent / "ticket-reducer.py"
    try:
        ticket_reducer = _load_module_from_path("ticket_reducer", reducer_path)
    except Exception:
        ticket_reducer = None  # type: ignore[assignment]

    unmapped_type_keys: set[str] = set()
    for issue in issues:
        issue = normalize_timestamps(issue)
        _process_single_issue(
            issue,
            tickets_root=tickets_root,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
            status_mapping=status_mapping,
            type_mapping=type_mapping,
            ticket_reducer=ticket_reducer,
            acli_client=acli_client,
            unmapped_type_keys=unmapped_type_keys,
        )

    creatable_issues = (
        [i for i in issues if i.get("key") not in unmapped_type_keys]
        if unmapped_type_keys
        else issues
    )
    write_create_events(
        creatable_issues,
        tickets_tracker=tickets_root,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
    )
    _write_success_checkpoint(checkpoint_file, run_id)


# ---------------------------------------------------------------------------
# __main__ entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import os

    # Read env vars
    jira_url = os.environ.get("JIRA_URL", "")
    jira_user = os.environ.get("JIRA_USER", "")
    jira_api_token = os.environ.get("JIRA_API_TOKEN", "")
    jira_project = os.environ.get("JIRA_PROJECT", "")
    bridge_env_id = os.environ.get("BRIDGE_ENV_ID", "")
    run_id = os.environ.get("GH_RUN_ID", "")
    checkpoint_path_str = os.environ.get("INBOUND_CHECKPOINT_PATH", "")
    overlap_buffer_minutes = int(os.environ.get("INBOUND_OVERLAP_BUFFER_MINUTES", "15"))
    status_mapping_str = os.environ.get("INBOUND_STATUS_MAPPING", "{}")
    type_mapping_str = os.environ.get("INBOUND_TYPE_MAPPING", "{}")

    # Parse JSON mapping strings
    status_mapping = json.loads(status_mapping_str)
    type_mapping = json.loads(type_mapping_str)

    # Load ACLI client
    script_dir = Path(__file__).resolve().parent
    acli_mod = _load_module_from_path(
        "acli_integration", script_dir / "acli-integration.py"
    )
    acli_client = acli_mod.AcliClient(
        jira_url=jira_url, user=jira_user, api_token=jira_api_token
    )

    # Read checkpoint
    if checkpoint_path_str:
        checkpoint_path = Path(checkpoint_path_str)
        if checkpoint_path.exists():
            checkpoint_data = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            last_pull_ts = checkpoint_data.get("last_pull_ts", "")
        else:
            last_pull_ts = "1970-01-01T00:00:00Z"
    else:
        checkpoint_path = None
        last_pull_ts = "1970-01-01T00:00:00Z"

    # Derive tickets_root from repo root
    repo_root = Path(__file__).resolve().parents[3]
    tickets_root = repo_root / ".tickets-tracker"

    config = {
        "bridge_env_id": bridge_env_id,
        "overlap_buffer_minutes": overlap_buffer_minutes,
        "status_mapping": status_mapping,
        "type_mapping": type_mapping,
        "checkpoint_file": str(checkpoint_path) if checkpoint_path is not None else "",
        "run_id": run_id,
        "project": jira_project,
    }

    process_inbound(
        tickets_root=tickets_root,
        acli_client=acli_client,
        last_pull_ts=last_pull_ts,
        config=config,
    )


# ---------------------------------------------------------------------------
# Inbound comment pull — dual-key dedup
# ---------------------------------------------------------------------------

_ORIGIN_UUID_RE = re.compile(r"<!-- origin-uuid: ([0-9a-f-]+) -->")


def _read_dedup_map(ticket_dir: Path) -> dict[str, Any]:
    """Read .jira-comment-map from ticket_dir. Returns empty structure if absent."""
    path = ticket_dir / ".jira-comment-map"
    if not path.exists():
        return {"uuid_to_jira_id": {}, "jira_id_to_uuid": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        # Ensure both keys exist
        data.setdefault("uuid_to_jira_id", {})
        data.setdefault("jira_id_to_uuid", {})
        return data
    except (OSError, json.JSONDecodeError):
        return {"uuid_to_jira_id": {}, "jira_id_to_uuid": {}}


def _write_dedup_map(ticket_dir: Path, dedup_map: dict[str, Any]) -> None:
    """Write .jira-comment-map atomically to ticket_dir."""
    path = ticket_dir / ".jira-comment-map"
    tmp_path = path.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(dedup_map, ensure_ascii=False), encoding="utf-8")
    tmp_path.rename(path)


def _strip_uuid_marker(body: str) -> str:
    """Remove the <!-- origin-uuid: ... --> line from body text."""
    return re.sub(r"\n?<!-- origin-uuid: [0-9a-f-]+ -->", "", body).rstrip()


# REVIEW-DEFENSE: pull_comments, _read_dedup_map, _write_dedup_map, and
# _strip_uuid_marker are all covered by tests/scripts/test_bridge_inbound_comment.py
# (6 unit tests written in batch 7, passing GREEN in this batch). Those tests
# exercise all code paths including primary dedup, secondary dedup, dedup-map
# update, and marker stripping via the pull_comments integration surface.
def pull_comments(
    jira_key: str,
    ticket_id: str,
    ticket_dir: Path,
    acli_client: Any,
    bridge_env_id: str,
) -> list[dict[str, Any]]:
    """Pull Jira comments for a ticket and write new COMMENT events locally.

    Dual-key dedup:
      - Primary: Jira comment ID checked against jira_id_to_uuid
      - Secondary: UUID marker in body checked against uuid_to_jira_id

    Args:
        jira_key: Jira issue key (e.g. "DSO-1").
        ticket_id: Local ticket ID.
        ticket_dir: Path to the ticket directory.
        acli_client: Object with get_comments(jira_key) method.
        bridge_env_id: UUID of this bridge environment.

    Returns:
        List of written COMMENT event dicts.
    """
    jira_comments = acli_client.get_comments(jira_key)
    dedup_map = _read_dedup_map(ticket_dir)
    jira_id_to_uuid = dedup_map["jira_id_to_uuid"]
    uuid_to_jira_id = dedup_map["uuid_to_jira_id"]

    written_events: list[dict[str, Any]] = []

    for comment in jira_comments:
        jira_comment_id = comment.get("id", "")
        body = comment.get("body", "")

        # Primary dedup: Jira comment ID
        if jira_comment_id in jira_id_to_uuid:
            continue

        # Secondary dedup: UUID marker in body
        marker_match = _ORIGIN_UUID_RE.search(body)
        if marker_match:
            origin_uuid = marker_match.group(1)
            if origin_uuid in uuid_to_jira_id:
                # Backfill primary key so subsequent pulls use the faster primary
                # dedup path instead of running secondary dedup again every pull.
                if jira_comment_id and jira_comment_id not in jira_id_to_uuid:
                    jira_id_to_uuid[jira_comment_id] = origin_uuid
                    _write_dedup_map(ticket_dir, dedup_map)
                continue

        # New comment — write COMMENT event
        ts = int(time.time())
        event_uuid = str(uuid.uuid4())
        stripped_body = _strip_uuid_marker(body)

        event: dict[str, Any] = {
            "event_type": "COMMENT",
            "uuid": event_uuid,
            "timestamp": ts,
            "env_id": bridge_env_id,
            "data": {"body": stripped_body},
        }

        # Write event file to disk
        filename = f"{ts}-{event_uuid}-COMMENT.json"
        event_path = ticket_dir / filename
        event_path.write_text(json.dumps(event, ensure_ascii=False), encoding="utf-8")

        # Update dedup map
        jira_id_to_uuid[jira_comment_id] = event_uuid
        uuid_to_jira_id[event_uuid] = jira_comment_id

        written_events.append(event)

    # Write updated dedup map atomically
    if written_events:
        _write_dedup_map(ticket_dir, dedup_map)

    return written_events
