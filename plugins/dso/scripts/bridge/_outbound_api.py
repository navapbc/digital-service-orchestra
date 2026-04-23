"""Public API functions for bridge-outbound: parsing, filtering, helpers."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import tempfile
import time
import uuid
from pathlib import Path
from types import ModuleType
from typing import Any

# Pattern: .tickets-tracker/<ticket-id>/<timestamp>-<uuid>-<EVENT_TYPE>.json
_EVENT_FILE_RE = re.compile(
    r"^\.tickets-tracker/([^/]+)/(\d+)-([0-9a-f-]+)-([A-Z]+)\.json$"
)


def load_module_from_path(name: str, path: Path) -> ModuleType:
    """Load a Python module from a filesystem path via importlib."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        msg = f"Cannot load module from {path}"
        raise ImportError(msg)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def parse_git_diff_events(diff_text: str) -> list[dict[str, Any]]:
    """Parse new event files from git diff --name-only output.

    Returns a list of dicts with keys: ticket_id, event_type, file_path.
    Non-event files (e.g. README.md) are silently ignored.
    """
    events: list[dict[str, Any]] = []
    for line in diff_text.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        match = _EVENT_FILE_RE.match(line)
        if match:
            ticket_id = match.group(1)
            event_type = match.group(4)
            events.append(
                {
                    "ticket_id": ticket_id,
                    "event_type": event_type,
                    "file_path": line,
                }
            )
    return events


def read_event_file(file_path: str | Path) -> dict[str, Any] | None:
    """Read and parse an event JSON file. Returns None on error."""
    try:
        with open(file_path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def filter_bridge_events(
    events: list[dict[str, Any]], bridge_env_id: str
) -> list[dict[str, Any]]:
    """Filter out events whose env_id matches the bridge env ID."""
    filtered: list[dict[str, Any]] = []
    for e in events:
        if "env_id" in e:
            if e["env_id"] != bridge_env_id:
                filtered.append(e)
            continue
        file_path = e.get("file_path", "")
        if file_path:
            event_data = read_event_file(file_path)
            if event_data and event_data.get("env_id") == bridge_env_id:
                continue
        filtered.append(e)
    return filtered


def get_compiled_status(ticket_dir: Path, *, reducer_path: Path) -> str | None:
    """Return the compiled/post-conflict-resolution status for a ticket."""
    ticket_reducer = load_module_from_path("ticket_reducer", reducer_path)
    state = ticket_reducer.reduce_ticket(str(ticket_dir))
    if state is None:
        return None
    return state.get("status")


def has_existing_sync(ticket_dir: Path) -> bool:
    """Return True if a SYNC event file already exists in the ticket directory."""
    return any(ticket_dir.glob("*-SYNC.json"))


def write_sync_event(
    ticket_dir: Path,
    jira_key: str,
    local_id: str,
    bridge_env_id: str,
    run_id: str = "",
) -> Path:
    """Write a SYNC event file to the ticket directory."""
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-SYNC.json"
    payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": local_id,
        "env_id": bridge_env_id,
        "timestamp": ts,
        "run_id": run_id,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload, ensure_ascii=False))
    return path


def read_dedup_map(ticket_dir: Path) -> dict[str, Any]:
    """Read .jira-comment-map from ticket_dir. Returns empty dict on missing/corrupt."""
    map_path = ticket_dir / ".jira-comment-map"
    try:
        with open(map_path, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"uuid_to_jira_id": {}, "jira_id_to_uuid": {}}


def write_dedup_map(ticket_dir: Path, dedup_map: dict[str, Any]) -> None:
    """Write .jira-comment-map atomically (write temp, rename)."""
    map_path = ticket_dir / ".jira-comment-map"
    fd, tmp_path = tempfile.mkstemp(dir=str(ticket_dir), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(dedup_map, f, ensure_ascii=False)
        os.replace(tmp_path, str(map_path))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def embed_uuid_marker(body: str, event_uuid: str) -> str:
    """Append <!-- origin-uuid: {event_uuid} --> as a new line at end of body."""
    return f"{body}\n<!-- origin-uuid: {event_uuid} -->"


def resolve_jira_key(ticket_dir: Path) -> str | None:
    """Resolve the Jira issue key for a ticket from its latest SYNC event file."""
    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    if not sync_files:
        return None
    sync_data = read_event_file(sync_files[-1])
    if not sync_data:
        return None
    return sync_data.get("jira_key") or None


def write_bridge_alert(
    ticket_dir: Path,
    ticket_id: str,
    reason: str,
    bridge_env_id: str = "",
) -> Path:
    """Write a BRIDGE_ALERT event file to the ticket directory."""
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-BRIDGE_ALERT.json"
    payload = {
        "event_type": "BRIDGE_ALERT",
        "timestamp": ts,
        "uuid": event_uuid,
        "env_id": bridge_env_id,
        "ticket_id": ticket_id,
        "data": {"reason": reason},
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload, ensure_ascii=False))
    return path
