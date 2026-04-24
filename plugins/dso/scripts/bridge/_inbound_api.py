"""Public API functions for bridge-inbound: fetch, normalize, write events."""

from __future__ import annotations

import json
import logging
import re
import time
import uuid
from collections.abc import Callable
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

try:
    from zoneinfo import ZoneInfo
except ImportError:  # Python < 3.9
    from backports.zoneinfo import ZoneInfo  # type: ignore[no-redef]

from bridge._atomic import atomic_write_json
from bridge._inbound_utils import parse_jira_timestamp

# Jira priority name → local 0-4 integer scale
_JIRA_PRIORITY_TO_LOCAL: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}

# Type hierarchy: lower index = higher rank.
_TYPE_HIERARCHY = ["epic", "story", "task", "chore", "bug"]


def fetch_jira_changes(
    acli_client: Any,
    *,
    last_pull_ts: str,
    overlap_buffer_minutes: int,
    project: str | None = None,
    on_batch_complete: Callable[[int], None] | None = None,
    start_at_override: int | None = None,
) -> list[dict[str, Any]]:
    """Fetch Jira issues updated since last_pull_ts minus overlap_buffer_minutes."""
    dt = datetime.fromisoformat(last_pull_ts.replace("Z", "+00:00"))
    buffered_dt = dt - timedelta(minutes=overlap_buffer_minutes)

    # Jira Cloud interprets unqualified JQL datetime strings in the service account's
    # profile timezone — NOT UTC. Fetch the account TZ and convert before formatting
    # so Jira receives local-time strings that round-trip correctly back to UTC.
    sa_tz_name = "UTC"
    try:
        myself = acli_client.get_myself()
        raw_tz = myself.get("timeZone")
        if isinstance(raw_tz, str) and raw_tz:
            sa_tz_name = raw_tz
    except Exception as exc:
        logging.warning(
            "fetch_jira_changes: could not determine service account timezone (%s); "
            "defaulting to UTC. Set the Jira service account profile TZ to UTC "
            "to suppress this warning.",
            exc,
        )
    try:
        sa_tz = ZoneInfo(sa_tz_name)
    except (KeyError, ValueError):
        logging.warning(
            "fetch_jira_changes: unrecognised timezone '%s'; defaulting to UTC",
            sa_tz_name,
        )
        sa_tz = ZoneInfo("UTC")
    buffered_local = buffered_dt.astimezone(sa_tz)
    buffered_ts_str = buffered_local.strftime("%Y-%m-%d %H:%M")

    jql = f'updatedDate >= "{buffered_ts_str}"'
    if project:
        _SAFE_PROJECT_RE = re.compile(r'["\\\[\]{}()|&;,]')
        sanitized_project = _SAFE_PROJECT_RE.sub("", project).strip()
        if not sanitized_project:
            msg = f"project key is empty after sanitization: {project!r}"
            raise ValueError(msg)
        jql = f'project = "{sanitized_project}" AND {jql}'

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
    """Convert Jira timestamp fields to UTC epoch ints."""
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
            dt = parse_jira_timestamp(value)
            fields[field_name] = int(dt.timestamp())

    return issue


def write_create_events(
    issues: list[dict[str, Any]],
    *,
    tickets_tracker: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> list[Path]:
    """Write CREATE event files for new Jira-originated tickets."""
    written: list[Path] = []

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

        if jira_key in synced_jira_keys:
            continue

        normalized_issue = normalize_timestamps(
            json.loads(json.dumps(issue))  # deep copy via JSON round-trip
        )

        local_id = f"jira-{jira_key.lower()}"

        ticket_dir = tickets_tracker / local_id
        ticket_dir.mkdir(parents=True, exist_ok=True)

        ts = time.time_ns()
        event_uuid = str(uuid.uuid4())
        filename = f"{ts}-{event_uuid}-CREATE.json"

        normalized_fields = normalized_issue.get("fields", {})

        jira_issuetype = normalized_fields.get("issuetype", {})
        jira_type_name = (
            jira_issuetype.get("name", "Task")
            if isinstance(jira_issuetype, dict)
            else "Task"
        )
        jira_summary = normalized_fields.get("summary", "")
        _raw_desc = normalized_fields.get("description", "")
        jira_description = (
            _raw_desc if isinstance(_raw_desc, str) and _raw_desc.strip() else None
        )

        jira_priority_obj = normalized_fields.get("priority", {})
        local_priority: int | None = None
        if isinstance(jira_priority_obj, dict):
            pname = jira_priority_obj.get("name", "")
            local_priority = _JIRA_PRIORITY_TO_LOCAL.get(pname)

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


def is_destructive_change(existing: dict[str, Any], inbound: dict[str, Any]) -> bool:
    """Return True if *inbound* would destructively overwrite *existing* data."""
    existing_desc = existing.get("description", "").strip()
    inbound_desc = inbound.get("description", "").strip()
    if existing_desc and not inbound_desc:
        return True

    existing_links = existing.get("links", [])
    inbound_links = inbound.get("links", [])
    if existing_links and len(inbound_links) < len(existing_links):
        return True

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
    """Write a bridge-authored STATUS event file for a Jira status change."""
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ts = time.time_ns()
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
    """Write a .jira-sync-status file recording a Jira relationship rejection."""
    ticket_dir.mkdir(parents=True, exist_ok=True)

    sync_status: dict[str, Any] = {
        "jira_sync_status": "rejected",
        "reason": reason,
    }

    status_path = ticket_dir / ".jira-sync-status"
    atomic_write_json(status_path, sync_status)
    return status_path


def write_edit_event(
    *,
    ticket_id: str,
    fields: dict[str, Any],
    ticket_dir: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> Path:
    """Write a bridge-authored EDIT event file for Jira field changes."""
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ts = time.time_ns()
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
    """Write a BRIDGE_ALERT event file for unmapped status/type values."""
    ticket_dir = tickets_root / ticket_id
    ticket_dir.mkdir(parents=True, exist_ok=True)

    ts = time.time_ns()
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
    """Check that the service account's Jira profile timezone is UTC.

    Jira Cloud interprets unqualified JQL datetime strings in the service account's
    profile timezone. This function checks that timezone via GET /rest/api/2/myself
    so mismatches are caught before fetching issues.
    """
    try:
        myself = acli_client.get_myself()
    except Exception as exc:
        logging.warning(
            "verify_jira_timezone_utc: could not fetch service account profile (%s); "
            "skipping timezone check.",
            exc,
        )
        return True
    tz = myself.get("timeZone", "")
    if tz == "UTC":
        return True

    logging.warning(
        "Jira service account timezone is '%s', expected 'UTC'. "
        "JQL datetime conversion will be applied automatically, but changing "
        "the Jira profile timezone to UTC is recommended.",
        tz,
    )
    return False
