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

from bridge._outbound_api import (  # noqa: E402
    filter_bridge_events,
    get_compiled_status,
    has_existing_sync,
    load_module_from_path as _load_module_from_path,
    parse_git_diff_events,
    write_bridge_alert,
)
from bridge._outbound_handlers import (  # noqa: E402
    handle_comment_event,
    handle_create_event,
    handle_edit_event,
    handle_file_impact_event,
    handle_link_event,
    handle_revert_event,
    handle_status_event,
    handle_unlink_event,
    sort_events_for_dispatch,
)

# Re-export detect_status_flap for backward compatibility
from bridge._flap import detect_status_flap  # noqa: E402

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
# process_outbound — thin dispatcher
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
    filtered = sort_events_for_dispatch(
        filter_bridge_events(events, bridge_env_id=bridge_env_id)
    )
    reducer_path = Path(__file__).resolve().parent / "ticket-reducer.py"
    # Shared kwargs passed to every handler
    ctx: dict[str, Any] = {
        "acli_client": acli_client,
        "tickets_root": tickets_root,
        "bridge_env_id": bridge_env_id,
        "run_id": run_id,
    }
    syncs: list[dict[str, Any]] = []
    _status_updated: set[str] = set()
    _link_types_cache: list[dict[str, Any]] | None = None
    _created_link_pairs: set[frozenset] = set()

    for event in filtered:
        event_type = event.get("event_type", "")

        if event_type == "CREATE":
            syncs.extend(handle_create_event(event, **ctx))

        elif event_type == "STATUS":
            handle_status_event(
                event,
                **ctx,
                reducer_path=reducer_path,
                flap_threshold=flap_threshold,
                flap_window_seconds=flap_window_seconds,
                status_updated=_status_updated,
            )

        elif event_type == "REVERT":
            syncs.extend(handle_revert_event(event, **ctx))

        elif event_type == "COMMENT":
            handle_comment_event(event, **ctx)

        elif event_type == "LINK":
            link_syncs, _link_types_cache = handle_link_event(
                event,
                **ctx,
                link_types_cache=_link_types_cache,
                created_link_pairs=_created_link_pairs,
            )
            syncs.extend(link_syncs)

        elif event_type == "UNLINK":
            syncs.extend(handle_unlink_event(event, **ctx))

        elif event_type == "EDIT":
            handle_edit_event(event, **ctx)

        elif event_type == "FILE_IMPACT":
            handle_file_impact_event(event, **ctx)

    return syncs


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
                # Use absolute paths so read_event_file can resolve them
                # regardless of the caller's CWD.
                git_diff_output = "\n".join(
                    str(p.resolve()) for p in tracker_dir.rglob("*.json")
                )
            else:
                git_diff_output = ""
        else:
            git_diff_output = "\n".join(
                f".tickets-tracker/{line}"  # tickets-boundary-ok: bridge constructs paths to events
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

    tickets_dir = ".tickets-tracker"  # tickets-boundary-ok: bridge root dir
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
