#!/usr/bin/env python3
"""Inbound bridge: pull Jira changes into local ticket system.

Fetches Jira issues via windowed JQL pull, normalizes timestamps to UTC epoch,
and writes CREATE event files for new Jira-originated tickets.

No external dependencies — uses importlib, json, os, pathlib, datetime.
"""

from __future__ import annotations

import json
import os
import sys
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
from datetime import datetime  # noqa: E402 — needed by _write_success_checkpoint
from bridge import (  # noqa: E402 — inbound event handlers
    check_destructive_guard,
    handle_edit,
    handle_links,
    handle_status,
    handle_type_check,
)

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


# ---------------------------------------------------------------------------
# Helper functions extracted from process_inbound
# ---------------------------------------------------------------------------


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

    # UTC health check — warn but continue; fetch_jira_changes converts the
    # buffered datetime to the service account's local TZ before formatting JQL.
    verify_jira_timezone_utc(acli_client)

    bridge_env_id = config.get("bridge_env_id", "")
    status_mapping = config.get("status_mapping", {})
    type_mapping = config.get("type_mapping", {})
    checkpoint_file = config.get("checkpoint_file", "")
    run_id = config.get("run_id", "")
    overlap_buffer_minutes = config.get("overlap_buffer_minutes", 15)
    project = config.get("project") or ""

    # Observability: emit run-start summary so success/failure is distinguishable in logs.
    # Bug 0e38-a5da: silent fetch regressions previously went undetected for 7+ days
    # because the script produced zero output on success.
    print(
        f"[inbound-bridge] start run={run_id} project={project or '(none)'} "
        f"window_start={last_pull_ts} overlap_minutes={overlap_buffer_minutes} "
        f"bridge_env_id={bridge_env_id[:8] if bridge_env_id else '(none)'}",
        flush=True,
    )

    issues = _fetch_issues_with_checkpoint(
        acli_client, last_pull_ts=last_pull_ts, config=config
    )

    print(f"[inbound-bridge] fetched {len(issues)} issue(s)", flush=True)

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

    # Observability: emit run-complete summary with issue disposition counts.
    # A window that expected issues but got zero is the canonical failure signal
    # for the silent-fetch regression (bug 0e38-a5da).
    print(
        f"[inbound-bridge] complete run={run_id} fetched={len(issues)} "
        f"unmapped_type={len(unmapped_type_keys)} create_events={len(creatable_issues)}",
        flush=True,
    )
    if len(issues) == 0:
        logging.warning(
            "[inbound-bridge] zero issues fetched for project=%r window_start=%s "
            "overlap=%sm — if you expected issues in this window, the fetch "
            "may be silently broken (bug 0e38-a5da).",
            project or "(none)",
            last_pull_ts,
            overlap_buffer_minutes,
        )
    _write_success_checkpoint(checkpoint_file, run_id)


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
