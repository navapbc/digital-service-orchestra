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
import logging
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from types import ModuleType
from typing import Any

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Pattern: .tickets-tracker/<ticket-id>/<timestamp>-<uuid>-<EVENT_TYPE>.json
_EVENT_FILE_RE = re.compile(
    r"^\.tickets-tracker/([^/]+)/(\d+)-([0-9a-f-]+)-([A-Z]+)\.json$"
)

# Local priority integer (0-4) → Jira priority name
_LOCAL_PRIORITY_TO_JIRA: dict[int, str] = {
    0: "Highest",
    1: "High",
    2: "Medium",
    3: "Low",
    4: "Lowest",
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


def _read_dedup_map(ticket_dir: Path) -> dict[str, Any]:
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


def _write_dedup_map(ticket_dir: Path, dedup_map: dict[str, Any]) -> None:
    """Write .jira-comment-map atomically (write temp, rename)."""
    map_path = ticket_dir / ".jira-comment-map"
    fd, tmp_path = tempfile.mkstemp(dir=str(ticket_dir), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(dedup_map, f, ensure_ascii=False)
        os.replace(tmp_path, str(map_path))
    except BaseException:
        # Clean up temp file on failure
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _embed_uuid_marker(body: str, event_uuid: str) -> str:
    """Append <!-- origin-uuid: {event_uuid} --> as a new line at end of body."""
    return f"{body}\n<!-- origin-uuid: {event_uuid} -->"


def detect_status_flap(
    ticket_dir: Path,
    *,
    flap_threshold: int = 3,
    window_seconds: int = 3600,
) -> bool:
    """Detect if a ticket is oscillating between statuses.

    Globs STATUS and BRIDGE_ALERT event files in ticket_dir, filters to those
    within window_seconds of now, extracts status values, and counts direction
    reversals (returning to a previously-seen status). Returns True if the
    reversal count >= flap_threshold.
    """
    # Collect all (timestamp, status) pairs from STATUS events
    all_status_events: list[tuple[int, str]] = []
    for path in ticket_dir.glob("*-STATUS.json"):
        data = _read_event_file(path)
        if data is None:
            continue
        ts = data.get("timestamp", 0)
        if not isinstance(ts, (int, float)):
            continue
        status = data.get("data", {}).get("status") or data.get("status")
        if status:
            all_status_events.append((int(ts), status))

    if not all_status_events:
        return False

    # Filter to events within window_seconds of the most recent event
    max_ts = max(ts for ts, _ in all_status_events)
    cutoff = max_ts - window_seconds
    status_events = [(ts, s) for ts, s in all_status_events if ts >= cutoff]

    # Sort by timestamp
    status_events.sort(key=lambda x: x[0])

    if len(status_events) < 2:
        return False

    # Count reversals: only increment when the status returns to a
    # previously-seen value (actual oscillation), not on sequential
    # progression through distinct statuses (e.g. A->B->C).
    flap_count = 0
    seen_statuses: set[str] = set()
    prev_status: str | None = None
    for _, status in status_events:
        if prev_status is not None and status != prev_status:
            if status in seen_statuses:
                flap_count += 1
        seen_statuses.add(status)
        prev_status = status

    return flap_count >= flap_threshold


def _resolve_jira_key(ticket_dir: Path) -> str | None:
    """Resolve the Jira issue key for a ticket from its latest SYNC event file.

    Returns the jira_key string, or None if no SYNC file exists or the file
    cannot be read or contains no jira_key field.
    """
    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    if not sync_files:
        return None
    sync_data = _read_event_file(sync_files[-1])
    if not sync_data:
        return None
    return sync_data.get("jira_key") or None


def write_bridge_alert(
    ticket_dir: Path,
    ticket_id: str,
    reason: str,
    bridge_env_id: str = "",
) -> Path:
    """Write a BRIDGE_ALERT event file to the ticket directory.

    Returns the path of the written file.
    """
    ts = int(time.time())
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


def process_outbound(
    events: list[dict[str, Any]],
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
    flap_threshold: int = 3,
    flap_window_seconds: int = 3600,
) -> list[dict[str, Any]]:
    """Process parsed events: filter, compile state, call acli, write SYNC events.

    Args:
        events: List of event dicts from parse_git_diff_events (or test fixtures).
        acli_client: Object with create_issue/update_issue/get_issue methods.
        tickets_root: Root directory containing ticket subdirectories.
        bridge_env_id: UUID of this bridge environment (for echo prevention).
        run_id: GitHub Actions run ID for traceability.
        flap_threshold: Number of status oscillations to trigger flap detection.
        flap_window_seconds: Time window in seconds for flap detection.

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

    # LINK/UNLINK caches: local to this process_outbound call
    # _link_types_cache: None = not yet fetched, list = fetched result
    _link_types_cache: list[dict[str, Any]] | None = None
    # _created_link_pairs: frozensets of (source_jira_key, target_jira_key) pairs
    # created in this run, for in-run reciprocal dedup
    _created_link_pairs: set[frozenset] = set()

    # Sort LINK/UNLINK events by timestamp before the main loop to ensure
    # chronological processing order and prevent state inconsistencies.
    # Non-LINK/UNLINK events use a large sentinel so their original relative
    # order is preserved (stable sort) and they appear after any LINK/UNLINK
    # event with an earlier timestamp.
    _SORT_SENTINEL = 2**62

    def _event_sort_key(ev: dict[str, Any]) -> int:
        if ev.get("event_type") in ("LINK", "UNLINK"):
            ev_data = _read_event_file(ev.get("file_path", ""))
            if ev_data:
                return int(ev_data.get("timestamp", _SORT_SENTINEL))
        return _SORT_SENTINEL

    filtered = sorted(filtered, key=_event_sort_key)

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

            # Guard: ensure title is non-empty before creating in Jira
            if not (ticket_data.get("title") or "").strip():
                ticket_data["title"] = f"[{ticket_id}]"

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

            # Flap detection: halt STATUS push if ticket is oscillating
            if detect_status_flap(
                ticket_dir,
                flap_threshold=flap_threshold,
                window_seconds=flap_window_seconds,
            ):
                logger.warning(
                    "STATUS flap detected for %s — halting outbound push",
                    ticket_id,
                )
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason=f"STATUS flap detected: oscillations within {flap_window_seconds}s window exceeded threshold ({flap_threshold})",
                    bridge_env_id=bridge_env_id,
                )
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

        elif event_type == "REVERT":
            # REVERT check-before-overwrite:
            # 1. Read the REVERT event file to determine target event uuid/type.
            # 2. If target is STATUS: fetch Jira state before pushing; emit
            #    BRIDGE_ALERT and skip if Jira has diverged; else push previous status.
            # 3. If target is COMMENT: emit BRIDGE_ALERT (manual cleanup required).
            # 4. REVERT-of-REVERT: treat as no-op (rejected at CLI layer).
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                logger.warning(
                    "REVERT event file unreadable for %s — skipping", ticket_id
                )
                continue

            revert_data = event_data.get("data", {})
            target_event_uuid = revert_data.get("target_event_uuid", "")
            target_event_type = revert_data.get("target_event_type", "")

            # Resolve jira_key from SYNC event (required for all REVERT paths)
            sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
            if not sync_files:
                logger.warning(
                    "REVERT for %s: no SYNC event found — cannot determine jira_key; skipping",
                    ticket_id,
                )
                continue
            sync_data = _read_event_file(sync_files[-1])
            if not sync_data:
                continue
            jira_key = sync_data.get("jira_key", "")
            if not jira_key:
                continue

            if target_event_type == "STATUS":
                # Collect all STATUS events in ticket_dir sorted by timestamp
                status_events_on_disk: list[tuple[int, str, str]] = []
                for spath in ticket_dir.glob("*-STATUS.json"):
                    sdata = _read_event_file(spath)
                    if sdata is None:
                        continue
                    sts = sdata.get("timestamp", 0)
                    suuid = sdata.get("uuid", "")
                    sstatus = sdata.get("data", {}).get("status", "")
                    if suuid and sstatus:
                        status_events_on_disk.append((int(sts), suuid, sstatus))
                status_events_on_disk.sort(key=lambda x: x[0])

                # Find the bad action event and determine the status it set
                bad_action_status: str | None = None
                bad_action_idx: int | None = None
                for idx, (_, suuid, sstatus) in enumerate(status_events_on_disk):
                    if suuid == target_event_uuid:
                        bad_action_status = sstatus
                        bad_action_idx = idx
                        break

                if bad_action_status is None or bad_action_idx is None:
                    logger.warning(
                        "REVERT for %s: target STATUS event %s not found in ticket dir",
                        ticket_id,
                        target_event_uuid,
                    )
                    continue

                # Fetch current Jira state BEFORE pushing any update
                jira_state = acli_client.get_issue(jira_key)
                current_jira_status = (
                    jira_state.get("status", "") if isinstance(jira_state, dict) else ""
                )

                # Check-before-overwrite: if Jira has diverged since bad action
                if current_jira_status != bad_action_status:
                    logger.warning(
                        "REVERT for %s: Jira status '%s' differs from bad action status '%s' "
                        "— Jira state has diverged; emitting BRIDGE_ALERT and skipping push",
                        ticket_id,
                        current_jira_status,
                        bad_action_status,
                    )
                    write_bridge_alert(
                        ticket_dir,
                        ticket_id=ticket_id,
                        reason=(
                            "REVERT check-before-overwrite: Jira state has diverged since bad "
                            "action. Manual review required."
                        ),
                        bridge_env_id=bridge_env_id,
                    )
                    continue

                # Jira matches expected — determine previous status to restore
                previous_status: str | None = None
                if bad_action_idx > 0:
                    previous_status = status_events_on_disk[bad_action_idx - 1][2]

                if previous_status:
                    acli_client.update_issue(jira_key, status=previous_status)
                    # Write SYNC for audit trail
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
                else:
                    logger.warning(
                        "REVERT for %s: no previous STATUS event found before bad action %s; "
                        "cannot determine revert target status",
                        ticket_id,
                        target_event_uuid,
                    )

            elif target_event_type == "COMMENT":
                # REVERT of COMMENT: Jira comments cannot be auto-deleted via this
                # bridge; emit BRIDGE_ALERT for manual cleanup.
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason="REVERT of COMMENT: Jira comment not removed (manual cleanup required)",
                    bridge_env_id=bridge_env_id,
                )

            elif target_event_type == "REVERT":
                # REVERT-of-REVERT is rejected at the CLI layer; treat as no-op here.
                logger.warning(
                    "REVERT for %s targets another REVERT event (%s) — treating as no-op",
                    ticket_id,
                    target_event_uuid,
                )

            else:
                # Unknown target type — treat as no-op with a warning
                logger.warning(
                    "REVERT for %s: unknown target_event_type '%s' — skipping",
                    ticket_id,
                    target_event_type,
                )

        elif event_type == "COMMENT":
            # Read event file to get uuid, body, and env_id
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            event_uuid = event_data.get("uuid", "")
            comment_body = event_data.get("data", {}).get("body", "")
            event_env_id = event_data.get("env_id", "")

            # Echo prevention: skip bridge-originated comments
            if event_env_id == bridge_env_id:
                continue

            # Must have an existing SYNC event to know the Jira key
            sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
            if not sync_files:
                continue

            sync_data = _read_event_file(sync_files[-1])
            if not sync_data:
                continue
            jira_key = sync_data.get("jira_key", "")
            if not jira_key:
                continue

            # Idempotency: check dedup map
            dedup_map = _read_dedup_map(ticket_dir)
            uuid_to_jira = dedup_map.get("uuid_to_jira_id", {})
            if event_uuid in uuid_to_jira:
                continue

            # Embed UUID marker in body
            body_with_marker = _embed_uuid_marker(comment_body, event_uuid)

            # Push comment to Jira
            result = acli_client.add_comment(jira_key, body_with_marker)
            jira_comment_id = result.get("id", "") if isinstance(result, dict) else ""

            if jira_comment_id:
                # Update dedup map
                jira_id_to_uuid = dedup_map.get("jira_id_to_uuid", {})
                uuid_to_jira[event_uuid] = jira_comment_id
                jira_id_to_uuid[jira_comment_id] = event_uuid
                dedup_map["uuid_to_jira_id"] = uuid_to_jira
                dedup_map["jira_id_to_uuid"] = jira_id_to_uuid
                _write_dedup_map(ticket_dir, dedup_map)

        elif event_type == "LINK":
            # Read event file to get relation, source_id, target_id
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            link_data = event_data.get("data", {})
            relation = link_data.get("relation", "")

            # Only process relates_to relation
            if relation != "relates_to":
                continue

            target_id = link_data.get("target_id", "")

            # Resolve source Jira key from SYNC file
            source_jira_key = _resolve_jira_key(ticket_dir)
            if not source_jira_key:
                continue

            # Resolve target Jira key from target ticket's SYNC file
            if not target_id:
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason="LINK event missing target_id — skipping",
                    bridge_env_id=bridge_env_id,
                )
                continue
            target_dir = tickets_root / target_id
            target_jira_key = _resolve_jira_key(target_dir)
            if target_jira_key is None:
                # Distinguish between missing SYNC and missing jira_key by checking sync files
                target_sync_files = sorted(target_dir.glob("*-SYNC.json"))
                if not target_sync_files:
                    reason = f"LINK event: target ticket {target_id} has no SYNC file (not yet synced to Jira) — skipping"
                else:
                    target_sync_data = _read_event_file(target_sync_files[-1])
                    if not target_sync_data:
                        reason = f"LINK event: target ticket {target_id} SYNC file unreadable — skipping"
                    else:
                        reason = f"LINK event: target ticket {target_id} SYNC file has no jira_key — skipping"
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason=reason,
                    bridge_env_id=bridge_env_id,
                )
                continue

            # Validate link type: cache get_issue_link_types result per run
            if _link_types_cache is None:
                _link_types_cache = acli_client.get_issue_link_types()
            link_types = _link_types_cache

            relates_type = next(
                (lt for lt in link_types if lt.get("name") == "Relates"), None
            )
            if relates_type is None:
                available = ", ".join(
                    lt.get("name", "") for lt in link_types if lt.get("name")
                )
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason=(
                        f"LINK event: 'Relates' link type not found in Jira instance. "
                        f"Available types: {available}"
                    ),
                    bridge_env_id=bridge_env_id,
                )
                continue

            # In-run reciprocal dedup: track created pairs as frozenset
            pair = frozenset([source_jira_key, target_jira_key])
            if pair in _created_link_pairs:
                continue

            # Pre-create dedup: check if Relates link already exists
            existing_links = acli_client.get_issue_links(source_jira_key)
            already_exists = False
            for link in existing_links:
                if link.get("type", {}).get("name") == "Relates":
                    outward = link.get("outwardIssue") or {}
                    inward = link.get("inwardIssue") or {}
                    if (
                        outward.get("key") == target_jira_key
                        or inward.get("key") == target_jira_key
                    ):
                        already_exists = True
                        break
            if already_exists:
                _created_link_pairs.add(pair)
                continue

            # Create link via set_relationship
            try:
                acli_client.set_relationship(
                    source_jira_key, target_jira_key, "Relates"
                )
                _created_link_pairs.add(pair)
                # Write SYNC event for traceability
                _write_sync_event(
                    ticket_dir,
                    jira_key=source_jira_key,
                    local_id=ticket_id,
                    bridge_env_id=bridge_env_id,
                    run_id=run_id,
                )
                syncs_written.append(
                    {
                        "event_type": "SYNC",
                        "jira_key": source_jira_key,
                        "local_id": ticket_id,
                    }
                )
            except subprocess.CalledProcessError as exc:
                logger.warning(
                    "LINK event: set_relationship(%s, %s) failed: %s — writing BRIDGE_ALERT",
                    source_jira_key,
                    target_jira_key,
                    exc,
                )
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason=(
                        f"LINK sync failed for {source_jira_key} -> {target_jira_key}: "
                        f"{exc.stderr or str(exc)}"
                    ),
                    bridge_env_id=bridge_env_id,
                )

        elif event_type == "UNLINK":
            # Read event file to get relation, source_id, target_id
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            link_data = event_data.get("data", {})
            relation = link_data.get("relation", "")

            # Only process relates_to relation
            if relation != "relates_to":
                continue

            target_id = link_data.get("target_id", "")

            # Resolve source Jira key from SYNC file
            source_jira_key = _resolve_jira_key(ticket_dir)
            if not source_jira_key:
                continue

            # Resolve target Jira key from target ticket's SYNC file
            if not target_id:
                continue
            target_dir = tickets_root / target_id
            target_jira_key = _resolve_jira_key(target_dir)
            if not target_jira_key:
                continue

            # Read-before-delete: get existing links for the source issue
            try:
                existing_links = acli_client.get_issue_links(source_jira_key)
            except subprocess.CalledProcessError:
                # Any ACLI error (e.g. source issue not found): treat as "already gone"
                continue

            # Find the matching link ID
            link_id_to_delete: str | None = None
            for link in existing_links:
                if link.get("type", {}).get("name") == "Relates":
                    outward = link.get("outwardIssue") or {}
                    inward = link.get("inwardIssue") or {}
                    if (
                        outward.get("key") == target_jira_key
                        or inward.get("key") == target_jira_key
                    ):
                        link_id_to_delete = link.get("id")
                        break

            if link_id_to_delete is None:
                # No matching link found — already gone or never created
                continue

            # Delete the link
            try:
                acli_client.delete_issue_link(link_id_to_delete)
                # Write SYNC event for audit trail after successful deletion
                _write_sync_event(
                    ticket_dir,
                    jira_key=source_jira_key,
                    local_id=ticket_id,
                    bridge_env_id=bridge_env_id,
                    run_id=run_id,
                )
                syncs_written.append(
                    {
                        "event_type": "SYNC",
                        "jira_key": source_jira_key,
                        "local_id": ticket_id,
                    }
                )
            except subprocess.CalledProcessError as exc:
                # 404 or 409: treat as "already gone" (concurrent deletion is idempotent).
                # ACLI Go process exit codes do not encode HTTP status — check stderr/stdout
                # for "not found" or "404" patterns to detect these cases.
                err_text = (exc.stderr or "") + (exc.stdout or "")
                if (
                    "404" in err_text
                    or "not found" in err_text.lower()
                    or "409" in err_text
                ):
                    continue
                # Other errors: write BRIDGE_ALERT and continue
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason=(
                        f"UNLINK sync failed for {source_jira_key} -> {target_jira_key}: "
                        f"{exc.stderr or str(exc)}"
                    ),
                    bridge_env_id=bridge_env_id,
                )

        elif event_type == "EDIT":
            # Read event file to get edited fields and env_id
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            # Echo prevention: skip bridge-originated edits
            event_env_id = event_data.get("env_id", "")
            if event_env_id == bridge_env_id:
                continue

            # Must have an existing SYNC event to know the Jira key
            sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
            if not sync_files:
                continue

            sync_data = _read_event_file(sync_files[-1])
            if not sync_data:
                continue
            jira_key = sync_data.get("jira_key", "")
            if not jira_key:
                continue

            # Extract edited fields and push to Jira
            edited_fields = event_data.get("data", {}).get("fields", {})
            if edited_fields:
                # Map local field names to ACLI update kwargs
                update_kwargs: dict[str, Any] = {}
                for field_name, field_value in edited_fields.items():
                    if field_name == "title":
                        update_kwargs["summary"] = str(field_value)
                    elif field_name == "priority":
                        # Convert local integer (0-4) to Jira priority name
                        if isinstance(field_value, int):
                            jira_pri_name = _LOCAL_PRIORITY_TO_JIRA.get(field_value)
                            if jira_pri_name:
                                update_kwargs["priority"] = jira_pri_name
                        else:
                            update_kwargs["priority"] = str(field_value)
                    elif field_name == "description":
                        # Empty description safeguard: never overwrite
                        # a Jira description with an empty string.
                        desc_str = str(field_value).strip()
                        if desc_str:
                            update_kwargs["description"] = desc_str
                    elif field_name == "ticket_type":
                        # Map local type to Jira type (capitalized)
                        update_kwargs["type"] = str(field_value).capitalize()
                    elif field_name == "assignee":
                        update_kwargs[field_name] = str(field_value)
                if update_kwargs:
                    acli_client.update_issue(jira_key, **update_kwargs)

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
        # Run git diff inside the tickets tracker worktree (orphan branch),
        # not the main repo. The tracker is a separate git worktree on the
        # 'tickets' branch; running diff on main's HEAD would always return
        # empty because ticket events are never committed to main.
        tracker_str = str(tickets_path)
        result = subprocess.run(
            ["git", "-C", tracker_str, "diff", "HEAD~1", "HEAD", "--name-only"],
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
                    # Prefix with .tickets-tracker/ so parse_git_diff_events
                    # regex still matches the expected path structure.
                    f".tickets-tracker/{p.relative_to(tracker_dir)}"
                    for p in tracker_dir.rglob("*.json")
                )
            else:
                git_diff_output = ""
        else:
            # Prefix paths with .tickets-tracker/ for parse_git_diff_events
            git_diff_output = "\n".join(
                f".tickets-tracker/{line}"
                for line in result.stdout.strip().split("\n")
                if line.strip()
            )

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


if __name__ == "__main__":
    import sys

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    # Read env vars (set by .github/workflows/outbound-bridge.yml)
    bridge_env_id = os.environ.get("BRIDGE_ENV_ID", "")
    run_id = os.environ.get("GH_RUN_ID", "")
    jira_url = os.environ.get("JIRA_URL", "")
    jira_user = os.environ.get("JIRA_USER", "")
    jira_api_token = os.environ.get("JIRA_API_TOKEN", "")
    jira_project = os.environ.get("JIRA_PROJECT", "")

    # Load ACLI client with outbound methods
    script_dir = Path(__file__).resolve().parent
    acli_mod = _load_module_from_path(
        "acli_integration", script_dir / "acli-integration.py"
    )
    acli_client = acli_mod.AcliClient(
        jira_url=jira_url,
        user=jira_user,
        api_token=jira_api_token,
        jira_project=jira_project,
    )

    tickets_dir = ".tickets-tracker"
    syncs = process_events(
        tickets_dir=tickets_dir,
        acli_client=acli_client,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
    )

    logger.info("Outbound bridge complete: %d SYNC events written", len(syncs))
    for s in syncs:
        logger.info("  %s -> %s", s.get("local_id", "?"), s.get("jira_key", "?"))

    sys.exit(0)
