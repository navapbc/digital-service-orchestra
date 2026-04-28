"""Event handler functions for bridge-outbound process_outbound dispatcher."""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path
from typing import Any

from bridge._flap import detect_status_flap
from bridge._outbound_api import (
    embed_uuid_marker,
    get_compiled_status,
    has_existing_sync,
    read_dedup_map as _read_dedup_map,
    read_event_file as _read_event_file,
    resolve_jira_key as _resolve_jira_key,
    write_bridge_alert,
    write_dedup_map as _write_dedup_map,
    write_sync_event as _write_sync_event,
)

logger = logging.getLogger(__name__)

_SORT_SENTINEL = 2**62


def sort_events_for_dispatch(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Sort events so LINK/UNLINK appear before other events (by timestamp).

    LINK and UNLINK events are sorted by their own file timestamp so that
    relationship operations are applied in chronological order; all other
    event types are placed after them (using a high sentinel value).
    """

    def _key(ev: dict[str, Any]) -> int:
        if ev.get("event_type") in ("LINK", "UNLINK"):
            ev_data = _read_event_file(ev.get("file_path", ""))
            if ev_data:
                return int(ev_data.get("timestamp", _SORT_SENTINEL))
        return _SORT_SENTINEL

    return sorted(events, key=_key)


# Local priority integer (0-4) → Jira priority name
_LOCAL_PRIORITY_TO_JIRA: dict[int, str] = {
    0: "Highest",
    1: "High",
    2: "Medium",
    3: "Low",
    4: "Lowest",
}


def handle_create_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> list[dict[str, Any]]:
    """Handle a CREATE event: create issue in Jira and write SYNC event."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    if has_existing_sync(ticket_dir):
        return []

    event_data = _read_event_file(event.get("file_path", ""))
    ticket_data = {}
    if event_data:
        ticket_data = event_data.get("data", {})

    if not (ticket_data.get("title") or "").strip():
        ticket_data["title"] = f"[{ticket_id}]"

    result = acli_client.create_issue(ticket_data)
    jira_key = result.get("key", "")

    if not jira_key:
        return []

    _write_sync_event(
        ticket_dir,
        jira_key=jira_key,
        local_id=ticket_id,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
    )
    return [
        {
            "event_type": "SYNC",
            "jira_key": jira_key,
            "local_id": ticket_id,
        }
    ]


def handle_status_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
    reducer_path: Path,
    flap_threshold: int = 3,
    flap_window_seconds: int = 3600,
    status_updated: set[str],
) -> list[dict[str, Any]]:
    """Handle a STATUS event: check flap, compile status, update Jira."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    if ticket_id in status_updated:
        return []

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
            reason=(
                f"STATUS flap detected: oscillations within "
                f"{flap_window_seconds}s window exceeded threshold ({flap_threshold})"
            ),
            bridge_env_id=bridge_env_id,
        )
        return []

    compiled_status = get_compiled_status(ticket_dir, reducer_path=reducer_path)
    if compiled_status:
        sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
        if sync_files:
            sync_data = _read_event_file(sync_files[-1])
            if sync_data:
                jira_key = sync_data.get("jira_key", "")
                if jira_key:
                    acli_client.update_issue(jira_key, status=compiled_status)
                    status_updated.add(ticket_id)
    else:
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason="STATUS event dropped: ticket-reducer returned empty compiled status",
            bridge_env_id=bridge_env_id,
        )

    return []


def _revert_status_event(
    ticket_id: str,
    ticket_dir: Path,
    jira_key: str,
    target_event_uuid: str,
    *,
    acli_client: Any,
    bridge_env_id: str,
    run_id: str,
) -> list[dict[str, Any]]:
    """Inner helper: revert a STATUS event by restoring the previous status."""
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
        return []

    jira_state = acli_client.get_issue(jira_key)
    current_jira_status = (
        jira_state.get("status", "") if isinstance(jira_state, dict) else ""
    )

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
        return []

    previous_status: str | None = None
    if bad_action_idx > 0:
        previous_status = status_events_on_disk[bad_action_idx - 1][2]

    if previous_status:
        acli_client.update_issue(jira_key, status=previous_status)
        _write_sync_event(
            ticket_dir,
            jira_key=jira_key,
            local_id=ticket_id,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )
        return [
            {
                "event_type": "SYNC",
                "jira_key": jira_key,
                "local_id": ticket_id,
            }
        ]

    logger.warning(
        "REVERT for %s: no previous STATUS event found before bad action %s; "
        "cannot determine revert target status",
        ticket_id,
        target_event_uuid,
    )
    return []


def handle_revert_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> list[dict[str, Any]]:
    """Handle a REVERT event: look up target event, undo Jira change if safe."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    event_data = _read_event_file(event.get("file_path", ""))
    if not event_data:
        logger.warning("REVERT event file unreadable for %s — skipping", ticket_id)
        return []

    revert_data = event_data.get("data", {})
    target_event_uuid = revert_data.get("target_event_uuid", "")
    target_event_type = revert_data.get("target_event_type", "")

    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    if not sync_files:
        logger.warning(
            "REVERT for %s: no SYNC event found — cannot determine jira_key; skipping",
            ticket_id,
        )
        return []
    sync_data = _read_event_file(sync_files[-1])
    if not sync_data:
        return []
    jira_key = sync_data.get("jira_key", "")
    if not jira_key:
        return []

    if target_event_type == "STATUS":
        return _revert_status_event(
            ticket_id,
            ticket_dir,
            jira_key,
            target_event_uuid,
            acli_client=acli_client,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )

    if target_event_type == "COMMENT":
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason="REVERT of COMMENT: Jira comment not removed (manual cleanup required)",
            bridge_env_id=bridge_env_id,
        )
        return []

    if target_event_type == "REVERT":
        logger.warning(
            "REVERT for %s targets another REVERT event (%s) — treating as no-op",
            ticket_id,
            target_event_uuid,
        )
        return []

    logger.warning(
        "REVERT for %s: unknown target_event_type '%s' — skipping",
        ticket_id,
        target_event_type,
    )
    return []


def handle_comment_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",  # accepted for uniform ctx unpacking; not used
) -> list[dict[str, Any]]:
    """Handle a COMMENT event: post comment to Jira with dedup guard."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    event_data = _read_event_file(event.get("file_path", ""))
    if not event_data:
        return []

    event_uuid = event_data.get("uuid", "")
    comment_body = event_data.get("data", {}).get("body", "")
    event_env_id = event_data.get("env_id", "")

    if event_env_id == bridge_env_id:
        return []

    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    if not sync_files:
        return []

    sync_data = _read_event_file(sync_files[-1])
    if not sync_data:
        return []
    jira_key = sync_data.get("jira_key", "")
    if not jira_key:
        return []

    dedup_map = _read_dedup_map(ticket_dir)
    uuid_to_jira = dedup_map.get("uuid_to_jira_id", {})
    if event_uuid in uuid_to_jira:
        return []

    body_with_marker = embed_uuid_marker(comment_body, event_uuid)
    result = acli_client.add_comment(jira_key, body_with_marker)
    jira_comment_id = result.get("id", "") if isinstance(result, dict) else ""

    if jira_comment_id:
        jira_id_to_uuid = dedup_map.get("jira_id_to_uuid", {})
        uuid_to_jira[event_uuid] = jira_comment_id
        jira_id_to_uuid[jira_comment_id] = event_uuid
        dedup_map["uuid_to_jira_id"] = uuid_to_jira
        dedup_map["jira_id_to_uuid"] = jira_id_to_uuid
        _write_dedup_map(ticket_dir, dedup_map)

    return []


def handle_link_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
    link_types_cache: list[dict[str, Any]] | None,
    created_link_pairs: set[frozenset],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]] | None]:
    """Handle a LINK event: create Jira issue link if not already present.

    Returns (syncs_written, updated_link_types_cache).
    """
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    event_data = _read_event_file(event.get("file_path", ""))
    if not event_data:
        return [], link_types_cache

    link_data = event_data.get("data", {})
    relation = link_data.get("relation", "")

    if relation != "relates_to":
        return [], link_types_cache

    target_id = link_data.get("target_id", "")

    source_jira_key = _resolve_jira_key(ticket_dir)
    if not source_jira_key:
        return [], link_types_cache

    if not target_id:
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason="LINK event missing target_id — skipping",
            bridge_env_id=bridge_env_id,
        )
        return [], link_types_cache

    target_dir = tickets_root / target_id
    target_jira_key = _resolve_jira_key(target_dir)
    if target_jira_key is None:
        target_sync_files = sorted(target_dir.glob("*-SYNC.json"))
        if not target_sync_files:
            reason = (
                f"LINK event: target ticket {target_id} has no SYNC file "
                "(not yet synced to Jira) — skipping"
            )
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
        return [], link_types_cache

    if link_types_cache is None:
        link_types_cache = acli_client.get_issue_link_types()
    link_types = link_types_cache

    relates_type = next((lt for lt in link_types if lt.get("name") == "Relates"), None)
    if relates_type is None:
        available = ", ".join(lt.get("name", "") for lt in link_types if lt.get("name"))
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason=(
                f"LINK event: 'Relates' link type not found in Jira instance. "
                f"Available types: {available}"
            ),
            bridge_env_id=bridge_env_id,
        )
        return [], link_types_cache

    pair = frozenset([source_jira_key, target_jira_key])
    if pair in created_link_pairs:
        return [], link_types_cache

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
        created_link_pairs.add(pair)
        return [], link_types_cache

    try:
        acli_client.set_relationship(source_jira_key, target_jira_key, "Relates")
        created_link_pairs.add(pair)
        _write_sync_event(
            ticket_dir,
            jira_key=source_jira_key,
            local_id=ticket_id,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )
        return [
            {
                "event_type": "SYNC",
                "jira_key": source_jira_key,
                "local_id": ticket_id,
            }
        ], link_types_cache
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
        return [], link_types_cache


def handle_unlink_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
) -> list[dict[str, Any]]:
    """Handle an UNLINK event: delete Jira issue link."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    event_data = _read_event_file(event.get("file_path", ""))
    if not event_data:
        return []

    link_data = event_data.get("data", {})
    relation = link_data.get("relation", "")

    if relation != "relates_to":
        return []

    target_id = link_data.get("target_id", "")

    source_jira_key = _resolve_jira_key(ticket_dir)
    if not source_jira_key:
        return []

    if not target_id:
        return []
    target_dir = tickets_root / target_id
    target_jira_key = _resolve_jira_key(target_dir)
    if not target_jira_key:
        return []

    try:
        existing_links = acli_client.get_issue_links(source_jira_key)
    except subprocess.CalledProcessError:
        return []

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
        return []

    try:
        acli_client.delete_issue_link(link_id_to_delete)
        _write_sync_event(
            ticket_dir,
            jira_key=source_jira_key,
            local_id=ticket_id,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )
        return [
            {
                "event_type": "SYNC",
                "jira_key": source_jira_key,
                "local_id": ticket_id,
            }
        ]
    except subprocess.CalledProcessError as exc:
        err_text = (exc.stderr or "") + (exc.stdout or "")
        if "404" in err_text or "not found" in err_text.lower() or "409" in err_text:
            return []
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason=(
                f"UNLINK sync failed for {source_jira_key} -> {target_jira_key}: "
                f"{exc.stderr or str(exc)}"
            ),
            bridge_env_id=bridge_env_id,
        )
        return []


def handle_file_impact_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",  # accepted for uniform ctx unpacking; not used
) -> list[dict[str, Any]]:
    """Handle a FILE_IMPACT event: record file impact as Jira property and post comment."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    event_data = _read_event_file(event.get("file_path", ""))
    if not event_data:
        return []

    event_uuid = event_data.get("uuid", "")
    file_impact = event_data.get("data", {}).get("file_impact", [])
    event_env_id = event_data.get("env_id", "")

    if event_env_id == bridge_env_id:
        return []

    jira_key = _resolve_jira_key(ticket_dir)
    if not jira_key:
        return []

    dedup_map = _read_dedup_map(ticket_dir)
    uuid_to_jira = dedup_map.get("uuid_to_jira_id", {})
    if event_uuid in uuid_to_jira:
        return []

    try:
        acli_client.set_issue_property(jira_key, "dso.file_impact", file_impact)
    except Exception:
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason="FILE_IMPACT_SYNC_FAILED",
            bridge_env_id=bridge_env_id,
        )
        return []

    paths = [
        entry.get("path", str(entry)) if isinstance(entry, dict) else str(entry)
        for entry in file_impact
    ]
    n = len(paths)
    file_word = "file" if n == 1 else "files"
    comment_body = f"File Impact ({n} {file_word}): {', '.join(paths)}"
    body_with_marker = embed_uuid_marker(comment_body, event_uuid)
    result = acli_client.add_comment(jira_key, body_with_marker)
    jira_comment_id = (result.get("id", "") if isinstance(result, dict) else "") or str(
        event_uuid
    )

    jira_id_to_uuid = dedup_map.get("jira_id_to_uuid", {})
    uuid_to_jira[event_uuid] = jira_comment_id
    jira_id_to_uuid[jira_comment_id] = event_uuid
    dedup_map["uuid_to_jira_id"] = uuid_to_jira
    dedup_map["jira_id_to_uuid"] = jira_id_to_uuid
    _write_dedup_map(ticket_dir, dedup_map)

    return []


def handle_edit_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",  # accepted for uniform ctx unpacking; not used
) -> list[dict[str, Any]]:
    """Handle an EDIT event: apply field updates to the Jira issue."""
    ticket_id = event.get("ticket_id", "")
    ticket_dir = tickets_root / ticket_id

    event_data = _read_event_file(event.get("file_path", ""))
    if not event_data:
        return []

    event_env_id = event_data.get("env_id", "")
    if event_env_id == bridge_env_id:
        return []

    sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
    if not sync_files:
        return []

    sync_data = _read_event_file(sync_files[-1])
    if not sync_data:
        return []
    jira_key = sync_data.get("jira_key", "")
    if not jira_key:
        return []

    edited_fields = event_data.get("data", {}).get("fields", {})
    if not edited_fields:
        return []

    update_kwargs: dict[str, Any] = {}
    for field_name, field_value in edited_fields.items():
        if field_name == "title":
            summary_str = str(field_value).strip()
            if summary_str:
                update_kwargs["summary"] = summary_str
        elif field_name == "priority":
            if isinstance(field_value, int):
                jira_pri_name = _LOCAL_PRIORITY_TO_JIRA.get(field_value)
                if jira_pri_name:
                    update_kwargs["priority"] = jira_pri_name
            else:
                update_kwargs["priority"] = str(field_value)
        elif field_name == "description":
            desc_str = str(field_value).strip()
            if desc_str:
                update_kwargs["description"] = desc_str
        elif field_name == "ticket_type":
            update_kwargs["type"] = str(field_value).capitalize()
        elif field_name == "assignee":
            assignee_str = str(field_value).strip()
            if assignee_str:
                update_kwargs[field_name] = assignee_str
    if update_kwargs:
        acli_client.update_issue(jira_key, **update_kwargs)

    return []
