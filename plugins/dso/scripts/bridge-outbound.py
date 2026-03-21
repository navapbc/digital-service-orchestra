#!/usr/bin/env python3
"""Outbound bridge: push local ticket changes to Jira.

Parses git diff output to detect new ticket events, applies echo prevention
and env_id filtering, uses compiled state for STATUS events (via ticket-reducer.py),
and calls acli-integration.py for Jira operations.

No external dependencies — uses importlib, json, os, pathlib, subprocess, time, uuid.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import time
import uuid
from pathlib import Path
from types import ModuleType
from typing import Any


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Pattern: .tickets-tracker/<ticket-id>/<timestamp>-<uuid>-<EVENT_TYPE>.json
_EVENT_FILE_RE = re.compile(
    r"^\.tickets-tracker/([^/]+)/(\d+)-([0-9a-f-]+)-([A-Z]+)\.json$"
)


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
# Public API
# ---------------------------------------------------------------------------


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


def filter_bridge_events(
    events: list[dict[str, Any]], bridge_env_id: str
) -> list[dict[str, Any]]:
    """Filter out events whose env_id matches the bridge env ID.

    Reads the actual event JSON file to check env_id, since parsed events
    from git diff only contain ticket_id, event_type, and file_path.
    Events whose file cannot be read are kept (not filtered).
    """
    filtered: list[dict[str, Any]] = []
    for e in events:
        # Check env_id from the event dict first (e.g. test fixtures)
        if "env_id" in e:
            if e["env_id"] != bridge_env_id:
                filtered.append(e)
            continue
        # Read env_id from the actual event file on disk
        file_path = e.get("file_path", "")
        if file_path:
            event_data = _read_event_file(file_path)
            if event_data and event_data.get("env_id") == bridge_env_id:
                continue
        filtered.append(e)
    return filtered


def get_compiled_status(ticket_dir: Path, *, reducer_path: Path) -> str | None:
    """Return the compiled/post-conflict-resolution status for a ticket.

    Loads ticket-reducer.py via importlib and calls reduce_ticket().
    Returns the status string or None if no valid state exists.
    """
    ticket_reducer = _load_module_from_path("ticket_reducer", reducer_path)
    state = ticket_reducer.reduce_ticket(str(ticket_dir))
    if state is None:
        return None
    return state.get("status")


def has_existing_sync(ticket_dir: Path) -> bool:
    """Return True if a SYNC event file already exists in the ticket directory."""
    return any(ticket_dir.glob("*-SYNC.json"))


def _read_event_file(file_path: str | Path) -> dict[str, Any] | None:
    """Read and parse an event JSON file. Returns None on error."""
    try:
        with open(file_path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _write_sync_event(
    ticket_dir: Path,
    jira_key: str,
    local_id: str,
    bridge_env_id: str,
    run_id: str = "",
) -> Path:
    """Write a SYNC event file to the ticket directory.

    Returns the path of the written file.
    """
    ts = int(time.time())
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


def process_outbound(
    events: list[dict[str, Any]],
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> list[dict[str, Any]]:
    """Process parsed events: filter, compile state, call acli, write SYNC events.

    Args:
        events: List of event dicts from parse_git_diff_events (or test fixtures).
        acli_client: Object with create_issue/update_issue/get_issue methods.
        tickets_root: Root directory containing ticket subdirectories.
        bridge_env_id: UUID of this bridge environment (for echo prevention).
        run_id: GitHub Actions run ID for traceability.

    Returns:
        List of SYNC event dicts that were written.
    """
    # Filter out bridge-originated events
    filtered = filter_bridge_events(events, bridge_env_id=bridge_env_id)

    syncs_written: list[dict[str, Any]] = []

    # Pre-compute reducer path once outside the loop
    reducer_path = Path(__file__).resolve().parent / "ticket-reducer.py"

    # Idempotency guard for STATUS events: track tickets whose status was
    # already pushed in this run to avoid duplicate Jira updates when the
    # same ticket appears multiple times in the event stream.
    _status_updated: set[str] = set()

    for event in filtered:
        ticket_id = event.get("ticket_id", "")
        event_type = event.get("event_type", "")
        ticket_dir = tickets_root / ticket_id

        if event_type == "CREATE":
            # Echo prevention: skip CREATE for tickets that already have a SYNC event
            if has_existing_sync(ticket_dir):
                continue
            # Read the event file to get ticket data
            event_data = _read_event_file(event.get("file_path", ""))
            ticket_data = {}
            if event_data:
                ticket_data = event_data.get("data", {})

            # Create issue in Jira
            result = acli_client.create_issue(ticket_data)
            jira_key = result.get("key", "")

            if jira_key:
                # Write SYNC event
                _write_sync_event(
                    ticket_dir,
                    jira_key=jira_key,
                    local_id=ticket_id,
                    bridge_env_id=bridge_env_id,
                    run_id=run_id,
                )
                syncs_written.append(
                    {
                        "event_type": "SYNC",
                        "jira_key": jira_key,
                        "local_id": ticket_id,
                    }
                )

        elif event_type == "STATUS":
            # Idempotency: skip if this ticket's status was already updated
            # in the current run (duplicate events in the same diff stream).
            if ticket_id in _status_updated:
                continue
            # Get compiled status via ticket-reducer
            compiled_status = get_compiled_status(ticket_dir, reducer_path=reducer_path)
            if compiled_status:
                # Find existing SYNC to get jira_key, or skip if none
                # For STATUS updates, we need to know the Jira key
                # Look for SYNC event in ticket dir
                sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
                if sync_files:
                    sync_data = _read_event_file(sync_files[-1])
                    if sync_data:
                        jira_key = sync_data.get("jira_key", "")
                        if jira_key:
                            acli_client.update_issue(jira_key, status=compiled_status)
                            _status_updated.add(ticket_id)

    return syncs_written


def process_events(
    tickets_dir: str | Path,
    acli_client: Any | None = None,
    git_diff_output: str | None = None,
    bridge_env_id: str | None = None,
    run_id: str = "",
) -> list[dict[str, Any]]:
    """Main entry point for the outbound bridge.

    Args:
        tickets_dir: Path to the .tickets-tracker directory.
        acli_client: Injectable ACLI client (defaults to importlib-loaded module).
        git_diff_output: Injectable git diff output (defaults to subprocess call).
        bridge_env_id: UUID of this bridge environment.
        run_id: GitHub Actions run ID for traceability.

    Returns:
        List of SYNC event dicts that were written.
    """
    tickets_path = Path(tickets_dir)

    # Default acli_client: load acli-integration.py via importlib
    if acli_client is None:
        acli_path = Path(__file__).resolve().parent / "acli-integration.py"
        acli_client = _load_module_from_path("acli_integration", acli_path)

    # Default git diff output: run git diff
    if git_diff_output is None:
        result = subprocess.run(
            ["git", "diff", "HEAD~1", "HEAD", "--name-only", "--", ".tickets-tracker/"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            # HEAD~1 does not exist (first commit): fall back to listing all
            # event files under .tickets-tracker/ so nothing is missed.
            tracker_dir = tickets_path
            if tracker_dir.is_dir():
                git_diff_output = "\n".join(
                    str(p.relative_to(tracker_dir.parent))
                    for p in tracker_dir.rglob("*.json")
                )
            else:
                git_diff_output = ""
        else:
            git_diff_output = result.stdout

    # Default bridge_env_id: read from .tickets-tracker/.env-id
    if bridge_env_id is None:
        env_id_path = tickets_path / ".env-id"
        if env_id_path.exists():
            bridge_env_id = env_id_path.read_text().strip()
        else:
            bridge_env_id = ""

    # Parse events from git diff
    events = parse_git_diff_events(git_diff_output)

    # Process events
    return process_outbound(
        events,
        acli_client=acli_client,
        tickets_root=tickets_path,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
    )
