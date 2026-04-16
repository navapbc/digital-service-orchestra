#!/usr/bin/env python3
"""Outbound bridge: push local ticket changes to Jira.

Parses git diff output to detect new ticket events, applies echo prevention
and env_id filtering, uses compiled state for STATUS events (via ticket-reducer.py),
and calls acli-integration.py for Jira operations.

No external dependencies — uses importlib, json, os, pathlib, subprocess, time, uuid.
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Ensure scripts directory is on sys.path so bridge package is importable
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

# ---------------------------------------------------------------------------
# Submodule imports
# ---------------------------------------------------------------------------

from bridge._flap import detect_status_flap  # noqa: E402
from bridge._outbound_api import (  # noqa: E402
    embed_uuid_marker,
    filter_bridge_events,
    get_compiled_status,
    has_existing_sync,
    load_module_from_path as _load_module_from_path,
    parse_git_diff_events,
    read_dedup_map as _read_dedup_map,
    read_event_file as _read_event_file,
    resolve_jira_key as _resolve_jira_key,
    write_bridge_alert,
    write_dedup_map as _write_dedup_map,
    write_sync_event as _write_sync_event,
)

# Re-export public symbols for backward compatibility
__all__ = [
    "parse_git_diff_events",
    "filter_bridge_events",
    "get_compiled_status",
    "has_existing_sync",
    "detect_status_flap",
    "write_bridge_alert",
    "process_outbound",
    "process_events",
]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Local priority integer (0-4) → Jira priority name
_LOCAL_PRIORITY_TO_JIRA: dict[int, str] = {
    0: "Highest",
    1: "High",
    2: "Medium",
    3: "Low",
    4: "Lowest",
}


# ---------------------------------------------------------------------------
# process_outbound (main handler — kept here per task instructions)
# ---------------------------------------------------------------------------


def process_outbound(
    events: list[dict[str, Any]],
    acli_client: Any,
    tickets_root: Path,
    bridge_env_id: str,
    run_id: str = "",
    flap_threshold: int = 3,
    flap_window_seconds: int = 3600,
) -> list[dict[str, Any]]:
    """Process parsed events: filter, compile state, call acli, write SYNC events."""
    filtered = filter_bridge_events(events, bridge_env_id=bridge_env_id)

    syncs_written: list[dict[str, Any]] = []

    reducer_path = Path(__file__).resolve().parent / "ticket-reducer.py"

    _status_updated: set[str] = set()

    _link_types_cache: list[dict[str, Any]] | None = None
    _created_link_pairs: set[frozenset] = set()

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
            if has_existing_sync(ticket_dir):
                continue
            event_data = _read_event_file(event.get("file_path", ""))
            ticket_data = {}
            if event_data:
                ticket_data = event_data.get("data", {})

            if not (ticket_data.get("title") or "").strip():
                ticket_data["title"] = f"[{ticket_id}]"

            result = acli_client.create_issue(ticket_data)
            jira_key = result.get("key", "")

            if jira_key:
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
            if ticket_id in _status_updated:
                continue

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

            compiled_status = get_compiled_status(ticket_dir, reducer_path=reducer_path)
            if compiled_status:
                sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
                if sync_files:
                    sync_data = _read_event_file(sync_files[-1])
                    if sync_data:
                        jira_key = sync_data.get("jira_key", "")
                        if jira_key:
                            acli_client.update_issue(jira_key, status=compiled_status)
                            _status_updated.add(ticket_id)
            else:
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason="STATUS event dropped: ticket-reducer returned empty compiled status",
                    bridge_env_id=bridge_env_id,
                )

        elif event_type == "REVERT":
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                logger.warning(
                    "REVERT event file unreadable for %s — skipping", ticket_id
                )
                continue

            revert_data = event_data.get("data", {})
            target_event_uuid = revert_data.get("target_event_uuid", "")
            target_event_type = revert_data.get("target_event_type", "")

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
                    continue

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
                    continue

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
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id,
                    reason="REVERT of COMMENT: Jira comment not removed (manual cleanup required)",
                    bridge_env_id=bridge_env_id,
                )

            elif target_event_type == "REVERT":
                logger.warning(
                    "REVERT for %s targets another REVERT event (%s) — treating as no-op",
                    ticket_id,
                    target_event_uuid,
                )

            else:
                logger.warning(
                    "REVERT for %s: unknown target_event_type '%s' — skipping",
                    ticket_id,
                    target_event_type,
                )

        elif event_type == "COMMENT":
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            event_uuid = event_data.get("uuid", "")
            comment_body = event_data.get("data", {}).get("body", "")
            event_env_id = event_data.get("env_id", "")

            if event_env_id == bridge_env_id:
                continue

            sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
            if not sync_files:
                continue

            sync_data = _read_event_file(sync_files[-1])
            if not sync_data:
                continue
            jira_key = sync_data.get("jira_key", "")
            if not jira_key:
                continue

            dedup_map = _read_dedup_map(ticket_dir)
            uuid_to_jira = dedup_map.get("uuid_to_jira_id", {})
            if event_uuid in uuid_to_jira:
                continue

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

        elif event_type == "LINK":
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            link_data = event_data.get("data", {})
            relation = link_data.get("relation", "")

            if relation != "relates_to":
                continue

            target_id = link_data.get("target_id", "")

            source_jira_key = _resolve_jira_key(ticket_dir)
            if not source_jira_key:
                continue

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

            pair = frozenset([source_jira_key, target_jira_key])
            if pair in _created_link_pairs:
                continue

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

            try:
                acli_client.set_relationship(
                    source_jira_key, target_jira_key, "Relates"
                )
                _created_link_pairs.add(pair)
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
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            link_data = event_data.get("data", {})
            relation = link_data.get("relation", "")

            if relation != "relates_to":
                continue

            target_id = link_data.get("target_id", "")

            source_jira_key = _resolve_jira_key(ticket_dir)
            if not source_jira_key:
                continue

            if not target_id:
                continue
            target_dir = tickets_root / target_id
            target_jira_key = _resolve_jira_key(target_dir)
            if not target_jira_key:
                continue

            try:
                existing_links = acli_client.get_issue_links(source_jira_key)
            except subprocess.CalledProcessError:
                continue

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
                continue

            try:
                acli_client.delete_issue_link(link_id_to_delete)
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
                err_text = (exc.stderr or "") + (exc.stdout or "")
                if (
                    "404" in err_text
                    or "not found" in err_text.lower()
                    or "409" in err_text
                ):
                    continue
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
            event_data = _read_event_file(event.get("file_path", ""))
            if not event_data:
                continue

            event_env_id = event_data.get("env_id", "")
            if event_env_id == bridge_env_id:
                continue

            sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
            if not sync_files:
                continue

            sync_data = _read_event_file(sync_files[-1])
            if not sync_data:
                continue
            jira_key = sync_data.get("jira_key", "")
            if not jira_key:
                continue

            edited_fields = event_data.get("data", {}).get("fields", {})
            if edited_fields:
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

    return syncs_written


def process_events(
    tickets_dir: str | Path,
    acli_client: Any | None = None,
    git_diff_output: str | None = None,
    bridge_env_id: str | None = None,
    run_id: str = "",
) -> list[dict[str, Any]]:
    """Main entry point for the outbound bridge."""
    tickets_path = Path(tickets_dir)

    if acli_client is None:
        acli_path = Path(__file__).resolve().parent / "acli-integration.py"
        acli_client = _load_module_from_path("acli_integration", acli_path)

    if git_diff_output is None:
        tracker_str = str(tickets_path)
        result = subprocess.run(
            ["git", "-C", tracker_str, "diff", "HEAD~1", "HEAD", "--name-only"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            tracker_dir = tickets_path
            if tracker_dir.is_dir():
                git_diff_output = "\n".join(
                    f".tickets-tracker/{p.relative_to(tracker_dir)}"
                    for p in tracker_dir.rglob("*.json")
                )
            else:
                git_diff_output = ""
        else:
            git_diff_output = "\n".join(
                f".tickets-tracker/{line}"
                for line in result.stdout.strip().split("\n")
                if line.strip()
            )

    if bridge_env_id is None:
        env_id_path = tickets_path / ".env-id"
        if env_id_path.exists():
            bridge_env_id = env_id_path.read_text().strip()
        else:
            bridge_env_id = ""

    events = parse_git_diff_events(git_diff_output)

    return process_outbound(
        events,
        acli_client=acli_client,
        tickets_root=tickets_path,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    bridge_env_id = os.environ.get("BRIDGE_ENV_ID", "")
    run_id = os.environ.get("GH_RUN_ID", "")
    jira_url = os.environ.get("JIRA_URL", "")
    jira_user = os.environ.get("JIRA_USER", "")
    jira_api_token = os.environ.get("JIRA_API_TOKEN", "")
    jira_project = os.environ.get("JIRA_PROJECT", "")

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
