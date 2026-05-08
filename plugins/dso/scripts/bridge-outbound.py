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
from bridge._outbound_cursor import (  # noqa: E402
    fetch_events_since_cursor,
    read_cursor,
    write_cursor,
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
    cursor_advance_fn: Any = None,
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
    success_count = 0
    failed_count = 0

    for event in filtered:
        event_type = event.get("event_type", "")
        ticket_id = event.get("ticket_id", "")

        # Per-event failure isolation (5ef3-24eb / DIG-1688): a handler
        # exception (e.g. acli_client.update_issue raising CalledProcessError)
        # must NOT abort the entire batch. Catch broadly, write a BRIDGE_ALERT
        # under the failing ticket's directory, leave the cursor unadvanced
        # for that event so the next run retries it, and continue.
        try:
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
        except Exception as exc:  # noqa: BLE001
            exc_class = type(exc).__name__
            logger.warning(
                "process_outbound: handler for ticket=%s event_type=%s failed "
                "with %s: %s — writing BRIDGE_ALERT and continuing",
                ticket_id,
                event_type,
                exc_class,
                exc,
            )
            ticket_dir = tickets_root / ticket_id if ticket_id else tickets_root
            try:
                if ticket_id:
                    ticket_dir.mkdir(parents=True, exist_ok=True)
                write_bridge_alert(
                    ticket_dir,
                    ticket_id=ticket_id or "__unknown__",
                    reason=(f"handler {event_type} failed with {exc_class}: {exc}"),
                    bridge_env_id=bridge_env_id,
                )
            except Exception as alert_exc:  # noqa: BLE001
                # Last-resort: even alert-writing failed. Log and keep going —
                # we still must not abort the batch.
                logger.error(
                    "process_outbound: failed to write BRIDGE_ALERT for "
                    "ticket=%s after handler failure: %s",
                    ticket_id,
                    alert_exc,
                )
            failed_count += 1
            # Do NOT advance cursor on failure — leave it at the failure
            # boundary so retry next run picks up that same event.
            continue
        else:
            success_count += 1

        # Advance cursor after each successful handler regardless of event_type —
        # last successful commit_sha wins, partial-success semantics handled at
        # process_events level (5d93-8b62). Wrapped in try/except so a cursor
        # write failure (filesystem permission / disk full) does not abort the
        # batch — preserves per-event failure isolation contract (5ef3-24eb).
        commit_sha = event.get("commit_sha", "")
        if cursor_advance_fn and commit_sha:
            try:
                cursor_advance_fn(commit_sha)
            except Exception as cursor_exc:  # noqa: BLE001
                logger.error(
                    "process_outbound: cursor_advance_fn failed for "
                    "ticket=%s commit_sha=%s: %s — batch continues, cursor "
                    "left at previous position (next run will retry)",
                    ticket_id,
                    commit_sha,
                    cursor_exc,
                )

    if failed_count:
        logger.info(
            "process_outbound: %d succeeded, %d failed",
            success_count,
            failed_count,
        )

    return syncs


def emit_migration_bridge_alert_if_needed(
    tickets_dir: Path, bridge_env_id: str
) -> None:
    """On first run with non-empty bridge_env_id, write a one-shot migration BRIDGE_ALERT.

    Uses .bridge-env-id-transition-marker sentinel in tickets_dir to ensure the alert
    fires exactly once when BRIDGE_ENV_ID transitions from empty/unset to a real value.
    Pre-migration events (env_id='') will not be retroactively replayed.
    """
    import json
    import time
    import uuid

    if not bridge_env_id:
        return
    sentinel = tickets_dir / ".bridge-env-id-transition-marker"
    if sentinel.exists():
        return
    ts = time.time_ns()
    alert_uuid = str(uuid.uuid4())
    filename = f"{ts}-{alert_uuid}-BRIDGE_ALERT.json"
    payload = {
        "event_type": "BRIDGE_ALERT",
        "timestamp": ts,
        "uuid": alert_uuid,
        "env_id": bridge_env_id,
        "ticket_id": "__migration__",
        "data": {
            "reason": (
                "pre_migration_events_not_replayed: BRIDGE_ENV_ID set for first time. "
                "Events authored before this run have env_id='' and will not be "
                "retroactively pushed to Jira."
            )
        },
    }
    alert_path = tickets_dir / filename
    alert_path.write_text(json.dumps(payload, ensure_ascii=False))
    sentinel.write_text(f"BRIDGE_ENV_ID set at {ts}\n")
    logger.info("Migration BRIDGE_ALERT written: %s", filename)


def process_events(
    tickets_dir: str | Path,
    acli_client: Any | None = None,
    git_diff_output: str | None = None,
    bridge_env_id: str | None = None,
    run_id: str = "",
    backfill: bool = False,
) -> list[dict[str, Any]]:
    """Main entry point for the outbound bridge.

    When ``backfill=True``, all JSON event files in *tickets_dir* are
    processed instead of only those added in the most recent git commit.
    Use this once to sync historical tickets that predate the bridge setup.
    """
    tickets_path = Path(tickets_dir)

    if acli_client is None:
        acli_path = Path(__file__).resolve().parent / "acli-integration.py"
        acli_client = _load_module_from_path("acli_integration", acli_path)

    if bridge_env_id is None:
        env_id_path = tickets_path / ".env-id"
        if env_id_path.exists():
            bridge_env_id = env_id_path.read_text().strip()
        else:
            bridge_env_id = ""

    if git_diff_output is not None:
        # Caller supplied a diff string directly (test fixtures, dispatcher).
        events = parse_git_diff_events(git_diff_output)
        return process_outbound(
            events,
            acli_client=acli_client,
            tickets_root=tickets_path,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )

    if backfill:
        # Backfill mode: scan every event file in the tracker directory so
        # historical tickets (created before the bridge was wired up) are
        # processed.  has_existing_sync() inside handle_create_event
        # prevents re-creating Jira issues for tickets that already have a
        # SYNC event, making this operation idempotent.
        if tickets_path.is_dir():
            git_diff_output = "\n".join(
                str(p.resolve()) for p in tickets_path.rglob("*.json")
            )
        else:
            git_diff_output = ""
        events = parse_git_diff_events(git_diff_output)
        return process_outbound(
            events,
            acli_client=acli_client,
            tickets_root=tickets_path,
            bridge_env_id=bridge_env_id,
            run_id=run_id,
        )

    # If the tracker directory is not a git repo (test fixtures, ad-hoc
    # invocations), fall back to rglob scanning — same legacy behavior as the
    # pre-cursor implementation when `git diff` failed.
    if (
        not (tickets_path / ".git").exists()
        and not (
            tickets_path.parent / ".git" / "worktrees" / tickets_path.name
        ).exists()
    ):
        rev_parse = subprocess.run(
            ["git", "-C", str(tickets_path), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        if rev_parse.returncode != 0:
            if tickets_path.is_dir():
                git_diff_output = "\n".join(
                    str(p.resolve()) for p in tickets_path.rglob("*.json")
                )
            else:
                git_diff_output = ""
            events = parse_git_diff_events(git_diff_output)
            return process_outbound(
                events,
                acli_client=acli_client,
                tickets_root=tickets_path,
                bridge_env_id=bridge_env_id,
                run_id=run_id,
            )

    # Cursor-based fetch (5d93-8b62): process all commits since last checkpoint
    # rather than only HEAD~1..HEAD, which loses events when multiple commits
    # land between bridge runs.
    cursor_sha = read_cursor(tickets_path)
    events_with_sha = fetch_events_since_cursor(
        tickets_path, cursor_sha, bridge_env_id or "", run_id
    )

    # Track per-event handler invocations so we know how far we got. The
    # processed_count counter increments after every dispatched handler;
    # if it equals len(events_with_sha) we processed everything.
    _processed_count = [0]

    def _cursor_advance(_sha: str) -> None:
        _processed_count[0] += 1

    syncs = process_outbound(
        events_with_sha,
        acli_client=acli_client,
        tickets_root=tickets_path,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
        cursor_advance_fn=_cursor_advance,
    )

    # Advance the cursor only if we have events to process. Use the HEAD SHA
    # from the fetched range so per-event reordering inside
    # sort_events_for_dispatch can't leave the cursor mid-range. If processing
    # was incomplete, leave the cursor where it is so the next run retries.
    #
    # Empty-fetch guard (f776-d7ef llm-review finding 1): when fetch returns
    # zero events (legitimately no new commits, or all events filtered as
    # bridge-origin echoes), `events_with_sha` is empty. The `events_with_sha and`
    # short-circuit below ensures we do NOT advance the cursor in that case —
    # preventing the silent-drop window where cursor jumps to HEAD without
    # processing anything. Cold-start handling (where the cursor SHOULD seed
    # at HEAD with no events processed) lives in fetch_events_since_cursor's
    # _seed_at_head, which writes the cursor and BRIDGE_ALERT directly.
    if events_with_sha and _processed_count[0] >= len(events_with_sha):
        head_sha_result = subprocess.run(
            ["git", "-C", str(tickets_path), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        if head_sha_result.returncode == 0 and head_sha_result.stdout.strip():
            write_cursor(tickets_path, head_sha_result.stdout.strip(), run_id)

    return syncs


if __name__ == "__main__":
    import argparse

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(
        description="Outbound bridge: push tickets to Jira"
    )
    parser.add_argument(
        "--backfill",
        action="store_true",
        default=False,
        help=(
            "Scan all event files in the tracker directory instead of only those "
            "added in the most recent git commit. Use once to sync historical tickets "
            "that predate the bridge setup. Operation is idempotent — tickets with an "
            "existing SYNC event are skipped automatically."
        ),
    )
    args = parser.parse_args()

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

    if args.backfill:
        logger.info("Backfill mode: scanning all tickets in tracker directory")

    tickets_dir = ".tickets-tracker"  # tickets-boundary-ok: bridge root dir
    syncs = process_events(
        tickets_dir=tickets_dir,
        acli_client=acli_client,
        bridge_env_id=bridge_env_id,
        run_id=run_id,
        backfill=args.backfill,
    )

    logger.info("Outbound bridge complete: %d SYNC events written", len(syncs))
    for s in syncs:
        logger.info("  %s -> %s", s.get("local_id", "?"), s.get("jira_key", "?"))

    sys.exit(0)
