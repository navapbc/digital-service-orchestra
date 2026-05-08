"""Event handler functions for bridge-outbound process_outbound dispatcher."""

from __future__ import annotations

import json
import logging
import os
import re
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


def _parse_user_map(env_val: str) -> dict[str, str]:
    """Parse BRIDGE_USER_MAP JSON string to a case-normalized dict.

    Keys are lowercased for case-insensitive email lookup.
    Returns empty dict on missing, empty, or malformed JSON (fail-open).
    """
    if not env_val or env_val.strip() == "{}":
        return {}
    try:
        raw = json.loads(env_val)
    except json.JSONDecodeError:
        logger.warning("BRIDGE_USER_MAP is not valid JSON — treating as empty map")
        return {}
    if not isinstance(raw, dict):
        return {}
    return {k.lower(): v for k, v in raw.items()}


def _resolve_assignee(
    name_or_email: str | None, user_map: dict[str, str]
) -> str | None:
    """Resolve a display name/email to a Jira accountId via BRIDGE_USER_MAP.

    Returns None when name_or_email is absent, not in map, or maps to empty string.
    Case-insensitive: both keys (at parse time) and lookup (here) are lowercased.
    """
    if not name_or_email or not user_map:
        return None
    account_id = user_map.get(name_or_email.lower())
    if not account_id:  # None or empty string → no-match
        return None
    return account_id


def _resolve_link_orientation(
    relation: str, source_jira_key: str, target_jira_key: str
) -> tuple[str, str, str]:
    """Map a local relation to (jira_link_type, out_key, in_key).

    Single source of truth used by both handle_link_event and
    handle_unlink_event so any future relation type or direction change is
    made in exactly one place. `depends_on` is the inverse of `blocks`, so
    its out/in are swapped.
    """
    if relation in ("relates_to", "supersedes"):
        return "Relates", source_jira_key, target_jira_key
    if relation == "blocks":
        return "Blocks", source_jira_key, target_jira_key
    # depends_on
    return "Blocks", target_jira_key, source_jira_key


def handle_create_event(
    event: dict[str, Any],
    *,
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
    _suppress_user_map_alert: bool = False,
) -> list[dict[str, Any]]:
    """Handle a CREATE event: create issue in Jira and write SYNC event.

    _suppress_user_map_alert: when True (set by handle_status_event's
    retroactive-CREATE path), skip writing the BRIDGE_USER_MAP no-map alert.
    The caller writes its own consolidated alert covering both the
    missing-SYNC condition and any retroactive-CREATE failure (b557-3bad).
    """
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

    # Resolve BRIDGE_USER_MAP for assignee
    user_map = _parse_user_map(os.environ.get("BRIDGE_USER_MAP", "{}"))
    raw_assignee = ticket_data.get("assignee")
    account_id = _resolve_assignee(raw_assignee, user_map)
    if account_id:
        ticket_data = dict(ticket_data)  # don't mutate original
        ticket_data["assignee"] = account_id
    elif raw_assignee:
        # No mapping found — remove assignee to let Jira default, then unassign explicitly
        ticket_data = dict(ticket_data)
        ticket_data.pop("assignee", None)

    result = acli_client.create_issue(ticket_data)
    jira_key = result.get("key", "")

    if not jira_key:
        return []

    if not account_id and raw_assignee and jira_key:
        # Write BRIDGE_ALERT for no-map entry (unless caller is retroactive
        # path which writes its own consolidated alert — b557-3bad)
        if not _suppress_user_map_alert:
            write_bridge_alert(
                ticket_dir,
                ticket_id=ticket_id,
                reason=f"no BRIDGE_USER_MAP entry for {raw_assignee}",
                bridge_env_id=bridge_env_id,
            )
        try:
            acli_client.unassign_issue(jira_key)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "unassign_issue failed for %s: %s — writing BRIDGE_ALERT", jira_key, exc
            )
            write_bridge_alert(
                ticket_dir,
                ticket_id=ticket_id,
                reason=f"unassign failed for {jira_key}: {exc}",
                bridge_env_id=bridge_env_id,
            )

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
        # Intercept 'deleted' BEFORE any generic update_issue call.
        # A deleted ticket must be removed from Jira, not transitioned.
        if compiled_status == "deleted":
            sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
            if not sync_files:
                # Ticket was never synced to Jira — skip silently
                logger.debug(
                    "STATUS 'deleted' for %s: no SYNC file found — ticket was never "
                    "synced to Jira; skipping deletion",
                    ticket_id,
                )
                return []
            sync_data = _read_event_file(sync_files[-1])
            if sync_data:
                jira_key = sync_data.get("jira_key", "")
                if jira_key:
                    try:
                        acli_client.delete_issue(jira_key)
                        status_updated.add(ticket_id)
                    except PermissionError as exc:
                        logger.warning(
                            "delete_issue(%s) denied (403) — writing BRIDGE_ALERT: %s",
                            jira_key,
                            exc,
                        )
                        write_bridge_alert(
                            ticket_dir,
                            ticket_id=ticket_id,
                            reason=f"403 delete denied for {jira_key}: {exc}",
                            bridge_env_id=bridge_env_id,
                        )
                    except subprocess.CalledProcessError as exc:
                        err_text = (exc.stderr or "") + (exc.stdout or "")
                        logger.warning(
                            "delete_issue(%s) failed — writing BRIDGE_ALERT: %s",
                            jira_key,
                            err_text.strip() or exc,
                        )
                        write_bridge_alert(
                            ticket_dir,
                            ticket_id=ticket_id,
                            reason=f"delete failed for {jira_key}: {err_text.strip() or exc}",
                            bridge_env_id=bridge_env_id,
                        )
                else:
                    logger.debug(
                        "STATUS 'deleted' for %s: SYNC file has no jira_key — skipping",
                        ticket_id,
                    )
            return []

        sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
        if sync_files:
            sync_data = _read_event_file(sync_files[-1])
            if sync_data:
                jira_key = sync_data.get("jira_key", "")
                if jira_key:
                    acli_client.update_issue(jira_key, status=compiled_status)
                    status_updated.add(ticket_id)
                else:
                    logger.warning(
                        "STATUS event dropped for %s: SYNC file present but "
                        "jira_key empty",
                        ticket_id,
                    )
                    write_bridge_alert(
                        ticket_dir,
                        ticket_id=ticket_id,
                        reason=(
                            "STATUS event dropped: SYNC file has no jira_key — "
                            "Jira link is broken; manual repair required"
                        ),
                        bridge_env_id=bridge_env_id,
                    )
        else:
            # No SYNC marker yet — the ticket was never successfully CREATEd in
            # Jira (e.g. a prior CREATE attempt failed transiently, or the
            # backfill aborted before this ticket's CREATE handler ran).
            # Attempt retroactive CREATE so the latest status can propagate
            # in this same run rather than being silently dropped. (7299-ff41)
            create_files = sorted(ticket_dir.glob("*-CREATE.json"))
            retroactive_attempted = bool(create_files)
            if create_files:
                synthetic_create_event = {
                    "ticket_id": ticket_id,
                    "file_path": str(create_files[-1]),
                }
                try:
                    create_syncs = handle_create_event(
                        synthetic_create_event,
                        acli_client=acli_client,
                        tickets_root=tickets_root,
                        bridge_env_id=bridge_env_id,
                        run_id=run_id,
                        _suppress_user_map_alert=True,
                    )
                except Exception as exc:  # noqa: BLE001
                    logger.warning(
                        "Retroactive CREATE for %s failed: %s — falling back to BRIDGE_ALERT",
                        ticket_id,
                        exc,
                    )
                    create_syncs = []

                retroactive_sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
                if create_syncs and retroactive_sync_files:
                    retroactive_sync = _read_event_file(retroactive_sync_files[-1])
                    retroactive_jira_key = (
                        retroactive_sync.get("jira_key", "") if retroactive_sync else ""
                    )
                    if retroactive_jira_key:
                        try:
                            acli_client.update_issue(
                                retroactive_jira_key, status=compiled_status
                            )
                            status_updated.add(ticket_id)
                            logger.info(
                                "Retroactive CREATE+STATUS for %s succeeded: %s -> %s",
                                ticket_id,
                                retroactive_jira_key,
                                compiled_status,
                            )
                            return create_syncs
                        except Exception as exc:  # noqa: BLE001
                            logger.warning(
                                "Retroactive STATUS update for %s (%s) failed: %s",
                                ticket_id,
                                retroactive_jira_key,
                                exc,
                            )

            # When retroactive-CREATE was attempted but didn't produce a SYNC
            # (e.g. the synthetic create_issue call failed), we still need ONE
            # alert that references the missing-SYNC condition so consumers can
            # detect dropped STATUS events. handle_create_event may have also
            # written its own no-map BRIDGE_USER_MAP alert; that's a separate
            # signal and is preserved. We deduplicate the previously-redundant
            # second SYNC alert by checking whether retroactive succeeded:
            # only write the SYNC alert when retroactive failed or wasn't
            # attempted (b557-3bad).
            #
            # Partial-success note (f776-d7ef llm-review finding 2): when
            # create_issue succeeds but the inner unassign_issue fails,
            # handle_create_event itself writes a dedicated unassign-failure
            # BRIDGE_ALERT (lines 154-159) before falling through to write the
            # SYNC. So the unassign failure IS surfaced to consumers — just via
            # the inner alert path, not via this outer SYNC alert. Suppressing
            # the redundant outer alert (when create_syncs is non-empty) does
            # NOT hide unassign failures.
            retroactive_succeeded = (
                bool(create_syncs) if retroactive_attempted else False
            )
            if retroactive_succeeded:
                return []

            logger.warning(
                "STATUS event dropped for %s: no SYNC.json marker — "
                "ticket has never been linked to Jira",
                ticket_id,
            )
            write_bridge_alert(
                ticket_dir,
                ticket_id=ticket_id,
                reason=(
                    "STATUS event dropped: no SYNC.json marker — ticket is not "
                    "linked to Jira (likely a Jira-originated ticket whose "
                    "inbound CREATE predates the SYNC-marker fix)"
                ),
                bridge_env_id=bridge_env_id,
            )
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

    # Supported relations and their Jira mapping:
    #   relates_to → "Relates" link type, source-outward
    #   blocks     → "Blocks"  link type, source-outward (source blocks target)
    #   depends_on → "Blocks"  link type, target-outward (target blocks source)
    #   supersedes → "Relates" link type, source-outward (Jira lacks supersedes;
    #                lossy mapping handled symmetrically on inbound)
    if relation not in ("relates_to", "blocks", "depends_on", "supersedes"):
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

    # Map relation → required Jira link type and outward-source orientation
    # via the shared helper (single source of truth with handle_unlink_event).
    required_type, out_key, in_key = _resolve_link_orientation(
        relation, source_jira_key, target_jira_key
    )

    if link_types_cache is None:
        link_types_cache = acli_client.get_issue_link_types()
    link_types = link_types_cache

    chosen_type = next(
        (lt for lt in link_types if lt.get("name") == required_type), None
    )
    if chosen_type is None:
        available = ", ".join(lt.get("name", "") for lt in link_types if lt.get("name"))
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason=(
                f"LINK event: '{required_type}' link type not found in Jira instance. "
                f"Available types: {available}"
            ),
            bridge_env_id=bridge_env_id,
        )
        return [], link_types_cache

    # Pair-key includes the link type so blocks(A,B) and relates_to(A,B) can
    # coexist as distinct edges within a single run.
    pair = frozenset([out_key, in_key, required_type])
    if pair in created_link_pairs:
        return [], link_types_cache

    existing_links = acli_client.get_issue_links(out_key)
    already_exists = False
    for link in existing_links:
        if link.get("type", {}).get("name") == required_type:
            outward = link.get("outwardIssue") or {}
            inward = link.get("inwardIssue") or {}
            # For directional types (Blocks), only outward match counts as
            # "same-direction"; inward match represents the inverse edge and
            # must NOT be treated as a duplicate.
            if required_type == "Blocks":
                if outward.get("key") == in_key:
                    already_exists = True
                    break
            else:
                if outward.get("key") == in_key or inward.get("key") == in_key:
                    already_exists = True
                    break
    if already_exists:
        created_link_pairs.add(pair)
        return [], link_types_cache

    try:
        acli_client.set_relationship(out_key, in_key, required_type)
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
            out_key,
            in_key,
            exc,
        )
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason=(
                f"LINK sync failed for {out_key} -> {in_key}: {exc.stderr or str(exc)}"
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

    if relation not in ("relates_to", "blocks", "depends_on", "supersedes"):
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

    required_type, out_key, in_key = _resolve_link_orientation(
        relation, source_jira_key, target_jira_key
    )

    try:
        existing_links = acli_client.get_issue_links(out_key)
    except subprocess.CalledProcessError:
        return []

    link_id_to_delete: str | None = None
    for link in existing_links:
        if link.get("type", {}).get("name") == required_type:
            outward = link.get("outwardIssue") or {}
            inward = link.get("inwardIssue") or {}
            if required_type == "Blocks":
                if outward.get("key") == in_key:
                    link_id_to_delete = link.get("id")
                    break
            else:
                if outward.get("key") == in_key or inward.get("key") == in_key:
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
    put_retry_uuids: set[str] = set(dedup_map.get("put_retry_uuids", []))

    # If comment already posted but PUT failed on a prior run, retry only the PUT.
    if event_uuid in uuid_to_jira and event_uuid in put_retry_uuids:
        try:
            acli_client.set_issue_property(jira_key, "dso.file_impact", file_impact)
            put_retry_uuids.discard(event_uuid)
            dedup_map["put_retry_uuids"] = list(put_retry_uuids)
            _write_dedup_map(ticket_dir, dedup_map)
        except Exception:
            write_bridge_alert(
                ticket_dir,
                ticket_id=ticket_id,
                reason="FILE_IMPACT_SYNC_FAILED",
                bridge_env_id=bridge_env_id,
            )
        return []

    if event_uuid in uuid_to_jira:
        return []

    put_failed = False
    try:
        acli_client.set_issue_property(jira_key, "dso.file_impact", file_impact)
    except Exception:
        put_failed = True

    paths = [
        entry.get("path", str(entry)) if isinstance(entry, dict) else str(entry)
        for entry in file_impact
    ]
    n = len(paths)
    file_word = "file" if n == 1 else "files"
    comment_body = f"File Impact ({n} {file_word}): {', '.join(paths)}"
    body_with_marker = embed_uuid_marker(comment_body, event_uuid)
    comment_failed = False
    try:
        result = acli_client.add_comment(jira_key, body_with_marker)
        jira_comment_id = (
            result.get("id", "") if isinstance(result, dict) else ""
        ) or str(event_uuid)
        jira_id_to_uuid = dedup_map.get("jira_id_to_uuid", {})
        uuid_to_jira[event_uuid] = jira_comment_id
        jira_id_to_uuid[jira_comment_id] = event_uuid
        dedup_map["uuid_to_jira_id"] = uuid_to_jira
        dedup_map["jira_id_to_uuid"] = jira_id_to_uuid
        if put_failed:
            # Dedup-mark the comment to prevent duplicate on retry, but flag the
            # PUT channel so the next invocation retries only the property write.
            put_retry_uuids.add(event_uuid)
            dedup_map["put_retry_uuids"] = list(put_retry_uuids)
        _write_dedup_map(ticket_dir, dedup_map)
    except Exception:
        comment_failed = True

    if put_failed:
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason="FILE_IMPACT_SYNC_FAILED",
            bridge_env_id=bridge_env_id,
        )
    if comment_failed:
        write_bridge_alert(
            ticket_dir,
            ticket_id=ticket_id,
            reason="FILE_IMPACT_COMMENT_SYNC_FAILED",
            bridge_env_id=bridge_env_id,
        )

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
        elif field_name == "tags":
            # Local tags (list[str]) → Jira labels. Jira labels are a
            # whitespace-free, comma-free single token per entry. Sanitize by
            # stripping whitespace and dropping empties; pass as a list so the
            # acli client can serialize accordingly.
            if isinstance(field_value, list):
                clean_labels = [
                    str(lbl).strip()
                    for lbl in field_value
                    if isinstance(lbl, str) and lbl.strip()
                ]
                update_kwargs["labels"] = clean_labels
            elif isinstance(field_value, str):
                clean_labels = [t.strip() for t in field_value.split(",") if t.strip()]
                update_kwargs["labels"] = clean_labels
        elif field_name == "parent_id":
            # Local parent_id → Jira parent (Epic Link / parent issue).
            # Translate local jira-{key} ticket id back to the bare Jira key
            # by looking up the parent ticket's SYNC marker; this avoids
            # leaking the local "jira-" prefix to Jira's parent field.
            parent_id = str(field_value).strip() if field_value is not None else ""
            if parent_id:
                parent_jira_key = _resolve_jira_key(tickets_root / parent_id)
                if parent_jira_key:
                    update_kwargs["parent"] = parent_jira_key
                else:
                    # Fall back to raw value for jira-prefixed ids (best effort:
                    # strip the "jira-" prefix and uppercase). Validate the
                    # result matches Jira key format (PROJECT-NUMBER) before
                    # passing to acli, so garbage like "jira-!!!invalid" is
                    # caught with a specific BRIDGE_ALERT instead of bubbling
                    # up as a generic handler exception.
                    if parent_id.lower().startswith("jira-"):
                        candidate = parent_id[len("jira-") :].upper()
                        if re.match(r"^[A-Z][A-Z0-9_]*-[0-9]+$", candidate):
                            update_kwargs["parent"] = candidate
                        else:
                            write_bridge_alert(
                                ticket_dir,
                                ticket_id=ticket_id,
                                reason=(
                                    f"EDIT parent_id={parent_id} skipped: "
                                    f"derived Jira key '{candidate}' does not "
                                    "match Jira key format (PROJECT-NUMBER)"
                                ),
                                bridge_env_id=bridge_env_id,
                            )
                    else:
                        # Unsynced local parent — surface via BRIDGE_ALERT but
                        # don't block the rest of the EDIT.
                        write_bridge_alert(
                            ticket_dir,
                            ticket_id=ticket_id,
                            reason=(
                                f"EDIT parent_id={parent_id} skipped: parent "
                                "ticket has no Jira SYNC marker"
                            ),
                            bridge_env_id=bridge_env_id,
                        )
    if update_kwargs:
        acli_client.update_issue(jira_key, **update_kwargs)

    return []
