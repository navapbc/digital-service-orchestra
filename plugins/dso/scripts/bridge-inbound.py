#!/usr/bin/env python3
"""Inbound bridge: pull Jira changes into local ticket system.

Fetches Jira issues via windowed JQL pull, normalizes timestamps to UTC epoch,
and writes CREATE event files for new Jira-originated tickets.

No external dependencies — uses importlib, json, os, pathlib, time, uuid, datetime, re.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Ensure scripts directory is on sys.path so bridge package is importable
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

# ---------------------------------------------------------------------------
# Submodule imports
# ---------------------------------------------------------------------------

from bridge._atomic import atomic_write_json as _atomic_write_json  # noqa: E402
from bridge._comments_inbound import (  # noqa: E402
    pull_comments,
)
from bridge._inbound_api import (  # noqa: E402
    fetch_jira_changes,
    is_destructive_change,
    map_status,
    map_type,
    normalize_timestamps,
    persist_relationship_rejection,
    verify_jira_timezone_utc,
    write_bridge_alert,
    write_create_events,
    write_edit_event,
    write_status_event,
)
from bridge._inbound_utils import load_module_from_path as _load_module_from_path  # noqa: E402

# Re-export for backward compatibility (callers that import from this module)
__all__ = [
    "fetch_jira_changes",
    "normalize_timestamps",
    "write_create_events",
    "is_destructive_change",
    "map_status",
    "map_type",
    "write_status_event",
    "persist_relationship_rejection",
    "write_edit_event",
    "write_bridge_alert",
    "verify_jira_timezone_utc",
    "pull_comments",
    "process_inbound",
]

# ---------------------------------------------------------------------------
# Constants (kept here for backward compat; also defined in _inbound_api.py)
# ---------------------------------------------------------------------------

_JIRA_PRIORITY_TO_LOCAL: dict[str, int] = {
    "Highest": 0,
    "High": 1,
    "Medium": 2,
    "Low": 3,
    "Lowest": 4,
}


# ---------------------------------------------------------------------------
# process_inbound (main handler — kept here per task instructions)
# ---------------------------------------------------------------------------


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
    import subprocess

    # UTC health check — halt if not UTC
    if not verify_jira_timezone_utc(acli_client):
        msg = "Jira service account timezone is not UTC — aborting inbound sync"
        logging.error(msg)
        raise RuntimeError(msg)

    overlap_buffer_minutes = config.get("overlap_buffer_minutes", 15)
    bridge_env_id = config.get("bridge_env_id", "")
    status_mapping = config.get("status_mapping", {})
    type_mapping = config.get("type_mapping", {})
    checkpoint_file = config.get("checkpoint_file", "")
    run_id = config.get("run_id", "")
    resume = config.get("resume", False)
    batch_resume_cursor = config.get("batch_resume_cursor")

    # Per-batch checkpoint callback
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

    project = config.get("project") or None

    try:
        issues = fetch_jira_changes(
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

    # Pre-load the ticket reducer module once
    reducer_path = Path(__file__).resolve().parent / "ticket-reducer.py"
    try:
        ticket_reducer = _load_module_from_path("ticket_reducer", reducer_path)
    except Exception:
        ticket_reducer = None  # type: ignore[assignment]

    _unmapped_type_keys: set[str] = set()

    for issue in issues:
        issue = normalize_timestamps(issue)

        fields = issue.get("fields", {})

        # --- Destructive change guard ---
        jira_key = issue.get("key", "")
        if jira_key:
            local_id = f"jira-{jira_key.lower()}"
            ticket_dir = tickets_root / local_id
            if ticket_dir.is_dir():
                sync_files = sorted(ticket_dir.glob("*-SYNC.json"))
                if sync_files:
                    try:
                        sync_data = json.loads(
                            sync_files[-1].read_text(encoding="utf-8")
                        )
                        existing_state = sync_data.get("data", {})
                        jira_issuelinks = fields.get("issuelinks", [])
                        inbound_links: list[str] = []
                        for jira_link in jira_issuelinks:
                            target_key = ""
                            if "outwardIssue" in jira_link:
                                target_key = jira_link["outwardIssue"].get("key", "")
                            elif "inwardIssue" in jira_link:
                                target_key = jira_link["inwardIssue"].get("key", "")
                            if target_key:
                                inbound_links.append(f"jira-{target_key.lower()}")
                        inbound_state: dict[str, Any] = {
                            "description": fields.get("description", ""),
                            "links": inbound_links,
                            "type": existing_state.get("type", ""),
                        }
                        jira_itype = (
                            fields.get("issuetype", {}).get("name", "")
                            if isinstance(fields.get("issuetype"), dict)
                            else ""
                        )
                        if jira_itype:
                            mapped_type = map_type(jira_itype, mapping=type_mapping)
                            if mapped_type:
                                inbound_state["type"] = mapped_type

                        if is_destructive_change(existing_state, inbound_state):
                            reason = (
                                f"Destructive change blocked for {local_id}: "
                                "inbound update would overwrite existing description/links/type"
                            )
                            logging.warning(reason)
                            write_bridge_alert(
                                ticket_id=local_id,
                                reason=reason,
                                tickets_root=tickets_root,
                                bridge_env_id=bridge_env_id,
                            )
                            continue
                    except (OSError, json.JSONDecodeError):
                        pass

        # Check status mapping
        jira_status = (
            fields.get("status", {}).get("name", "")
            if isinstance(fields.get("status"), dict)
            else ""
        )
        if jira_status and map_status(jira_status, mapping=status_mapping) is None:
            local_id = f"jira-{issue.get('key', 'unknown').lower()}"
            write_bridge_alert(
                ticket_id=local_id,
                reason=f"Unknown status value: '{jira_status}'",
                tickets_root=tickets_root,
                bridge_env_id=bridge_env_id,
            )

        # Write STATUS event if Jira status differs from local compiled status
        if jira_status:
            mapped_local_status = map_status(jira_status, mapping=status_mapping)
            if mapped_local_status is not None:
                jira_key_for_status = issue.get("key", "")
                if jira_key_for_status:
                    local_id_for_status = f"jira-{jira_key_for_status.lower()}"
                    ticket_dir_for_status = tickets_root / local_id_for_status
                    if ticket_dir_for_status.is_dir():
                        status_files = list(ticket_dir_for_status.glob("*-STATUS.json"))
                        current_local_status = ""
                        if status_files:
                            best_ts = -1
                            for sf in status_files:
                                try:
                                    sf_data = json.loads(sf.read_text(encoding="utf-8"))
                                    sf_ts = sf_data.get("timestamp", 0)
                                    if (
                                        isinstance(sf_ts, (int, float))
                                        and sf_ts > best_ts
                                    ):
                                        best_ts = sf_ts
                                        current_local_status = sf_data.get(
                                            "data", {}
                                        ).get("status", "")
                                except (OSError, json.JSONDecodeError):
                                    pass
                        if mapped_local_status != current_local_status:
                            write_status_event(
                                ticket_id=local_id_for_status,
                                status=mapped_local_status,
                                ticket_dir=ticket_dir_for_status,
                                bridge_env_id=bridge_env_id,
                                run_id=run_id,
                            )

        # Write EDIT events for field changes
        jira_key_for_edit = issue.get("key", "")
        if jira_key_for_edit:
            local_id_for_edit = f"jira-{jira_key_for_edit.lower()}"
            ticket_dir_for_edit = tickets_root / local_id_for_edit
            if ticket_dir_for_edit.is_dir() and ticket_reducer is not None:
                try:
                    local_state = ticket_reducer.reduce_ticket(str(ticket_dir_for_edit))
                except Exception:
                    local_state = None

                if local_state and isinstance(local_state, dict):
                    edit_fields: dict[str, Any] = {}

                    jira_pri_obj = fields.get("priority", {})
                    if isinstance(jira_pri_obj, dict):
                        pri_name = jira_pri_obj.get("name", "")
                        mapped_pri = _JIRA_PRIORITY_TO_LOCAL.get(pri_name)
                        if mapped_pri is not None and mapped_pri != local_state.get(
                            "priority"
                        ):
                            edit_fields["priority"] = mapped_pri

                    jira_asn_obj = fields.get("assignee", {})
                    if isinstance(jira_asn_obj, dict):
                        jira_asn_name = jira_asn_obj.get(
                            "displayName", jira_asn_obj.get("emailAddress", "")
                        )
                        if jira_asn_name and jira_asn_name != local_state.get(
                            "assignee"
                        ):
                            edit_fields["assignee"] = jira_asn_name

                    jira_title = fields.get("summary", "")
                    if jira_title and jira_title != local_state.get("title"):
                        edit_fields["title"] = jira_title

                    jira_desc = fields.get("description", "")
                    if isinstance(jira_desc, str) and jira_desc.strip():
                        local_desc = local_state.get("description") or ""
                        if jira_desc != local_desc:
                            edit_fields["description"] = jira_desc

                    if edit_fields:
                        write_edit_event(
                            ticket_id=local_id_for_edit,
                            fields=edit_fields,
                            ticket_dir=ticket_dir_for_edit,
                            bridge_env_id=bridge_env_id,
                            run_id=run_id,
                        )

        # Check type mapping
        jira_type = (
            fields.get("issuetype", {}).get("name", "")
            if isinstance(fields.get("issuetype"), dict)
            else ""
        )
        if jira_type and map_type(jira_type, mapping=type_mapping) is None:
            local_id = f"jira-{issue.get('key', 'unknown').lower()}"
            write_bridge_alert(
                ticket_id=local_id,
                reason=f"Unknown type value: '{jira_type}'",
                tickets_root=tickets_root,
                bridge_env_id=bridge_env_id,
            )
            if issue.get("key"):
                _unmapped_type_keys.add(issue["key"])
            continue

        # Process Jira issue links
        issue_links = fields.get("issuelinks", [])
        if issue_links:
            jira_key_for_links = issue.get("key", "")
            if jira_key_for_links:
                local_id_for_links = f"jira-{jira_key_for_links.lower()}"
                ticket_dir_for_links = tickets_root / local_id_for_links
                ticket_dir_for_links.mkdir(parents=True, exist_ok=True)
                for link in issue_links:
                    link_type = link.get("type", {}).get("name", "")
                    target_key = ""
                    if "outwardIssue" in link:
                        target_key = link["outwardIssue"].get("key", "")
                    elif "inwardIssue" in link:
                        target_key = link["inwardIssue"].get("key", "")
                    if link_type and target_key:
                        if link_type == "Relates":
                            target_local_id = f"jira-{target_key.lower()}"
                            ts = int(time.time())
                            event_uuid = str(uuid.uuid4())
                            filename = f"{ts}-{event_uuid[:8]}-LINK.json"
                            link_event: dict[str, Any] = {
                                "event_type": "LINK",
                                "ticket_id": local_id_for_links,
                                "timestamp": ts,
                                "uuid": event_uuid,
                                "env_id": bridge_env_id,
                                "data": {
                                    "source_id": local_id_for_links,
                                    "target_id": target_local_id,
                                    "relation": "relates_to",
                                },
                            }
                            (ticket_dir_for_links / filename).write_text(
                                json.dumps(link_event)
                            )
                            target_dir = tickets_root / target_local_id
                            target_dir.mkdir(parents=True, exist_ok=True)
                            recip_uuid = str(uuid.uuid4())
                            recip_filename = f"{ts}-{recip_uuid[:8]}-LINK.json"
                            recip_link_event: dict[str, Any] = {
                                "event_type": "LINK",
                                "ticket_id": target_local_id,
                                "timestamp": ts,
                                "uuid": recip_uuid,
                                "env_id": bridge_env_id,
                                "data": {
                                    "source_id": target_local_id,
                                    "target_id": local_id_for_links,
                                    "relation": "relates_to",
                                },
                            }
                            (target_dir / recip_filename).write_text(
                                json.dumps(recip_link_event)
                            )
                        elif hasattr(acli_client, "set_relationship"):
                            try:
                                acli_client.set_relationship(
                                    jira_key_for_links, target_key, link_type
                                )
                            except Exception as rel_exc:
                                reason = str(rel_exc)
                                persist_relationship_rejection(
                                    ticket_id=local_id_for_links,
                                    ticket_dir=ticket_dir_for_links,
                                    reason=reason,
                                )
                                write_bridge_alert(
                                    ticket_id=local_id_for_links,
                                    reason=f"Jira rejected relationship: {reason}",
                                    tickets_root=tickets_root,
                                    bridge_env_id=bridge_env_id,
                                )

    # Write CREATE events for new issues
    creatable_issues = (
        [i for i in issues if i.get("key") not in _unmapped_type_keys]
        if _unmapped_type_keys
        else issues
    )
    write_create_events(
        creatable_issues,
        tickets_tracker=tickets_root,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
    )

    # Update checkpoint ONLY on full success
    if checkpoint_file:
        from datetime import datetime, timezone

        new_ts = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        checkpoint_data: dict[str, Any] = {"last_pull_ts": new_ts}
        if run_id:
            checkpoint_data["last_run_id"] = run_id
        _atomic_write_json(Path(checkpoint_file), checkpoint_data)


# ---------------------------------------------------------------------------
# __main__ entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
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

    status_mapping = json.loads(status_mapping_str)
    type_mapping = json.loads(type_mapping_str)

    script_dir = Path(__file__).resolve().parent
    acli_mod = _load_module_from_path(
        "acli_integration", script_dir / "acli-integration.py"
    )
    acli_client = acli_mod.AcliClient(
        jira_url=jira_url, user=jira_user, api_token=jira_api_token
    )

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
