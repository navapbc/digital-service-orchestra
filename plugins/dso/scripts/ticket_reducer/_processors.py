"""Event-type processors for the ticket reducer.

Each function takes the current mutable state dict, the parsed event dict,
and any ancillary data needed (e.g. filepath for conflict recording), and
applies the event's effect to state in-place.  All processors return None.
"""

from __future__ import annotations

import json
import os
import sys


def process_create(
    state: dict,
    event: dict,
    data: dict,
    ticket_id: str,
    cache_path: str,
    dir_hash: str,
) -> dict | None:
    """Apply a CREATE event to state.

    Returns a fsck_needed error-state dict if required fields are missing,
    otherwise mutates state in-place and returns None.
    """
    from ticket_reducer._state import make_error_dict

    if not data.get("ticket_type") or not data.get("title"):
        fsck_result = make_error_dict(ticket_id, "fsck_needed", "corrupt_create_event")
        # Write the fsck result to cache immediately so callers get consistent results
        try:
            cache_tmp = cache_path + ".tmp"
            with open(cache_tmp, "w", encoding="utf-8") as tf:
                json.dump(
                    {"dir_hash": dir_hash, "state": fsck_result},
                    tf,
                    ensure_ascii=False,
                )
            os.rename(cache_tmp, cache_path)
        except OSError:
            pass
        return fsck_result

    state["ticket_id"] = ticket_id
    state["ticket_type"] = data.get("ticket_type")
    state["title"] = data.get("title")
    state["author"] = event.get("author")
    state["created_at"] = event.get("timestamp")
    state["env_id"] = event.get("env_id")
    state["parent_id"] = data.get("parent_id") or None
    state["priority"] = data.get("priority")
    state["assignee"] = data.get("assignee")
    state["description"] = data.get("description") or ""
    state["tags"] = data.get("tags", [])
    return None


def process_status(state: dict, event: dict, data: dict, filepath: str) -> None:
    """Apply a STATUS event: update state.status or record an optimistic-concurrency conflict."""
    current_status = data.get("current_status")
    if current_status is not None and current_status != state["status"]:
        if "conflicts" not in state:
            state["conflicts"] = []
        state["conflicts"].append(
            {
                "event_file": os.path.basename(filepath),
                "expected": current_status,
                "actual": state["status"],
                "target": data.get("status"),
            }
        )
    else:
        state["status"] = data.get("status", state["status"])


def process_comment(state: dict, event: dict, data: dict) -> None:
    """Apply a COMMENT event: append normalized body to state.comments.

    Coerces non-string bodies (e.g. Jira ADF dicts) to JSON string so
    downstream string-parsing consumers never receive a dict (b108-f088).
    Uses explicit None check — truthiness check treats {} as falsy (6bc8-91bc).
    """
    _raw_body = data.get("body")
    if _raw_body is None:
        _raw_body = ""
    elif not isinstance(_raw_body, str):
        _raw_body = json.dumps(_raw_body)
    state["comments"].append(
        {
            "body": _raw_body,
            "author": event.get("author"),
            "timestamp": event.get("timestamp"),
        }
    )


def process_link(state: dict, event: dict, data: dict) -> None:
    """Apply a LINK event: append a dep entry to state.deps."""
    state["deps"].append(
        {
            "target_id": data.get("target_id", data.get("target", "")),
            "relation": data.get("relation", ""),
            "link_uuid": event["uuid"],
        }
    )


def process_unlink(state: dict, data: dict) -> None:
    """Apply an UNLINK event: remove the dep entry matching link_uuid (noop if unknown)."""
    link_uuid_to_remove = data.get("link_uuid")
    state["deps"] = [
        d for d in state["deps"] if d.get("link_uuid") != link_uuid_to_remove
    ]


def process_bridge_alert(state: dict, event: dict, data: dict, event_uuid: str) -> None:
    """Apply a BRIDGE_ALERT event: add or resolve an alert in state.bridge_alerts.

    Reason normalization: prefer data.alert_type (inbound), fall back to
    data.reason (outbound), then data.detail, then empty string.
    Resolution: resolves_uuid (test contract) takes precedence over alert_uuid (spec).
    """
    reason = data.get("alert_type") or data.get("reason") or data.get("detail") or ""
    if data.get("resolved"):
        target_uuid = data.get("resolves_uuid") or data.get("alert_uuid")
        matched = False
        for existing in state["bridge_alerts"]:
            if existing.get("uuid") == target_uuid:
                existing["resolved"] = True
                matched = True
        if not matched:
            state["bridge_alerts"].append(
                {
                    "uuid": event_uuid,
                    "reason": reason,
                    "timestamp": event.get("timestamp"),
                    "resolved": True,
                }
            )
    else:
        state["bridge_alerts"].append(
            {
                "uuid": event_uuid,
                "reason": reason,
                "timestamp": event.get("timestamp"),
                "resolved": False,
            }
        )


def process_revert(state: dict, event: dict, data: dict, event_uuid: str) -> None:
    """Apply a REVERT event: append a revert record to state.reverts."""
    state["reverts"].append(
        {
            "uuid": event_uuid,
            "target_event_uuid": data.get("target_event_uuid"),
            "target_event_type": data.get("target_event_type"),
            "reason": data.get("reason", ""),
            "timestamp": event.get("timestamp"),
            "author": event.get("author"),
        }
    )


def process_edit(state: dict, data: dict) -> None:
    """Apply an EDIT event: merge data.fields into state (last-writer-wins).

    Tags stored as comma-separated string in event; convert to list.
    If the value is already a list (e.g. from a SNAPSHOT), keep it.
    Unknown field names (not present in state) are silently ignored.
    """
    fields = data.get("fields", {})
    for field_name, new_value in fields.items():
        if field_name not in state:
            continue
        if field_name == "tags":
            if isinstance(new_value, list):
                state["tags"] = new_value
            elif isinstance(new_value, str):
                state["tags"] = [t.strip() for t in new_value.split(",") if t.strip()]
            else:
                state["tags"] = []
        else:
            state[field_name] = new_value


def process_archived(state: dict) -> None:
    """Apply an ARCHIVED event: set state.archived = True."""
    state["archived"] = True


def process_snapshot(state: dict, data: dict) -> None:
    """Apply a SNAPSHOT event: restore all fields from compiled_state."""
    compiled_state = data.get("compiled_state", {})
    for key, value in compiled_state.items():
        state[key] = value


def scan_for_latest_snapshot(
    event_files: list[str],
) -> tuple[int | None, set[str]]:
    """Pass 1: scan all events to find the latest SNAPSHOT index and its source UUIDs.

    Returns (latest_snapshot_idx, snapshot_source_uuids).
    latest_snapshot_idx is None if no SNAPSHOT was found.
    """
    latest_snapshot_idx: int | None = None
    snapshot_source_uuids: set[str] = set()

    for idx, filepath in enumerate(event_files):
        try:
            with open(filepath, encoding="utf-8") as f:
                event = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        if event.get("event_type") == "SNAPSHOT":
            latest_snapshot_idx = idx
            snapshot_source_uuids = set(
                event.get("data", {}).get("source_event_uuids", [])
            )

    return latest_snapshot_idx, snapshot_source_uuids


def replay_events(
    state: dict,
    event_files: list[str],
    ticket_id: str,
    cache_path: str,
    dir_hash: str,
) -> tuple[int, dict | None]:
    """Pass 2: replay events onto state, applying each processor in order.

    Skips events before the latest SNAPSHOT index and events whose UUID appears
    in snapshot_source_uuids (already captured in the SNAPSHOT compiled_state).

    Returns (valid_event_count, early_return_result).
    early_return_result is non-None only when a corrupt CREATE is encountered
    (returns the fsck_needed error dict immediately).
    """
    latest_snapshot_idx, snapshot_source_uuids = scan_for_latest_snapshot(event_files)
    start_idx = latest_snapshot_idx if latest_snapshot_idx is not None else 0
    valid_event_count = 0

    for idx, filepath in enumerate(event_files):
        try:
            with open(filepath, encoding="utf-8") as f:
                event = json.load(f)
        except (json.JSONDecodeError, OSError):
            print(f"WARNING: skipping corrupt event {filepath}", file=sys.stderr)
            continue

        valid_event_count += 1

        if idx < start_idx:
            continue

        event_uuid = event.get("uuid", "")
        if event_uuid and event_uuid in snapshot_source_uuids:
            continue

        event_type = event.get("event_type", "")
        data = event.get("data", {})

        if event_type == "CREATE":
            result = process_create(state, event, data, ticket_id, cache_path, dir_hash)
            if result is not None:
                return valid_event_count, result
        elif event_type == "STATUS":
            process_status(state, event, data, filepath)
        elif event_type == "COMMENT":
            process_comment(state, event, data)
        elif event_type == "LINK":
            process_link(state, event, data)
        elif event_type == "UNLINK":
            process_unlink(state, data)
        elif event_type == "BRIDGE_ALERT":
            process_bridge_alert(state, event, data, event_uuid)
        elif event_type == "REVERT":
            process_revert(state, event, data, event_uuid)
        elif event_type == "EDIT":
            process_edit(state, data)
        elif event_type == "ARCHIVED":
            process_archived(state)
        elif event_type == "SNAPSHOT":
            process_snapshot(state, data)
        # Unknown event types are silently ignored

    return valid_event_count, None
