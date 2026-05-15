"""SHA-based checkpoint cursor for the outbound bridge.

Stores the last-processed commit SHA so the bridge processes all new events
since the previous run, not just those in HEAD~1..HEAD.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from bridge._atomic import atomic_write_json

CHECKPOINT_FILENAME = ".outbound-checkpoint.json"

logger = logging.getLogger(__name__)


def read_cursor(tracker_path: Path) -> str | None:
    """Read last_processed_sha from checkpoint. Returns None on missing/malformed/missing key."""
    checkpoint = tracker_path / CHECKPOINT_FILENAME
    if not checkpoint.exists():
        return None
    try:
        data = json.loads(checkpoint.read_text(encoding="utf-8"))
        sha = data.get("last_processed_sha")
        if isinstance(sha, str) and sha:
            return sha
        logger.warning("_outbound_cursor: checkpoint missing last_processed_sha field")
        return None
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("_outbound_cursor: malformed checkpoint (%s)", exc)
        return None


def write_cursor(tracker_path: Path, sha: str, run_id: str = "") -> None:
    """Atomically write last_processed_sha to checkpoint file."""
    checkpoint = tracker_path / CHECKPOINT_FILENAME
    atomic_write_json(checkpoint, {"last_processed_sha": sha, "last_run_id": run_id})


def write_cursor_bridge_alert(
    tracker_path: Path, reason: str, bridge_env_id: str = ""
) -> Path:
    """Write a BRIDGE_ALERT for cursor-level events (no ticket context).

    Writes to tracker_path/__bridge__/ (sentinel pseudo-ticket dir) since
    cursor events have no associated ticket_id.
    """
    alert_dir = tracker_path / "__bridge__"
    alert_dir.mkdir(parents=True, exist_ok=True)
    ts = time.time_ns()
    event_uuid = str(uuid.uuid4())
    filename = f"{ts}-{event_uuid}-BRIDGE_ALERT.json"
    payload: dict[str, Any] = {
        "event_type": "BRIDGE_ALERT",
        "timestamp": ts,
        "uuid": event_uuid,
        "env_id": bridge_env_id,
        "ticket_id": "__bridge__",
        "data": {"reason": reason},
    }
    path = alert_dir / filename
    try:
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    except OSError as exc:
        # Alert emission is best-effort — log loudly so an operator can see the
        # cursor failed to surface its alert (disk full, permission denied,
        # etc.) rather than discovering it via a missing alert file later.
        # The caller has already taken its corrective action (e.g., seed_at_head
        # wrote the cursor); failing alert emission must not abort the cursor
        # path. Bug f776-d7ef llm-review finding 3.
        logger.warning(
            "_outbound_cursor: failed to write BRIDGE_ALERT to %s: %s", path, exc
        )
    return path


def _seed_at_head(
    tracker_path: Path, bridge_env_id: str = "", run_id: str = ""
) -> list[dict[str, Any]]:
    """Write cursor at HEAD, emit BRIDGE_ALERT, return empty event list."""
    result = subprocess.run(
        ["git", "-C", str(tracker_path), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        logger.warning("_outbound_cursor: cannot rev-parse HEAD in %s", tracker_path)
        return []
    head_sha = result.stdout.strip()
    write_cursor(tracker_path, head_sha, run_id)
    write_cursor_bridge_alert(
        tracker_path,
        reason="outbound-checkpoint reset: cold-start/recovery",
        bridge_env_id=bridge_env_id,
    )
    return []


def fetch_events_since_cursor(
    tracker_path: Path,
    cursor_sha: str | None,
    bridge_env_id: str = "",
    run_id: str = "",
    cap: int = 500,
) -> list[dict[str, Any]]:
    """Fetch event files added since cursor_sha, returning event dicts with commit_sha field.

    Cold-start (cursor_sha is None) or unreachable SHA triggers seed_at_head:
    - Writes cursor at HEAD
    - Emits BRIDGE_ALERT
    - Returns empty list (no events pushed this run)

    Fetch strategy:
    1. git fetch --deepen=50 origin tickets (widen shallow clone; best-effort)
    2. Try git log cursor..HEAD --diff-filter=A --name-only --format=%H
    3. If SHA still unreachable: git fetch --unshallow origin tickets, retry
    4. If commit count > cap: write BRIDGE_ALERT + seed_at_head
    """

    def _run_git_log(cursor: str | None) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
        # Cold-start (cursor=None): walk full tracker history (no range arg).
        # Otherwise: walk cursor..HEAD.
        range_arg = [f"{cursor}..HEAD"] if cursor else []
        return subprocess.run(
            [
                "git",
                "-C",
                str(tracker_path),
                "log",
                "--diff-filter=A",
                "--name-only",
                "--format=%H",
                *range_arg,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    if cursor_sha is None:
        # Cold-start (bug f8a9-2cb0): walk full tracker history to surface
        # every pre-existing CREATE/event so the first bridge run against a
        # tracker with prior tickets does not silently drop them. Cap
        # protection still applies (handled below).
        logger.info("_outbound_cursor: cold-start — walking full tracker history")
        log_result = _run_git_log(None)
        if log_result.returncode != 0:
            logger.warning(
                "_outbound_cursor: cold-start git log failed (%s) — seeding at HEAD",
                log_result.stderr.strip(),
            )
            return _seed_at_head(tracker_path, bridge_env_id, run_id)
    else:
        # Step 1: widen shallow clone (best-effort; ignore failures e.g. local-only repos)
        subprocess.run(
            [
                "git",
                "-C",
                str(tracker_path),
                "fetch",
                "--deepen=50",
                "origin",
                "tickets",
            ],
            capture_output=True,
            check=False,
        )

        log_result = _run_git_log(cursor_sha)

    # Step 3: if SHA unreachable, try --unshallow
    if log_result.returncode != 0 and (
        "unknown revision" in log_result.stderr
        or "bad object" in log_result.stderr
        or "ambiguous argument" in log_result.stderr
    ):
        logger.info(
            "_outbound_cursor: cursor SHA %s unreachable after deepen — trying --unshallow",
            cursor_sha,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(tracker_path),
                "fetch",
                "--unshallow",
                "origin",
                "tickets",
            ],
            capture_output=True,
            check=False,
        )
        log_result = _run_git_log(cursor_sha)

    # SHA still unreachable after unshallow → seed_at_head
    if log_result.returncode != 0:
        logger.warning(
            "_outbound_cursor: cursor SHA %s unreachable after unshallow — seeding at HEAD",
            cursor_sha,
        )
        return _seed_at_head(tracker_path, bridge_env_id, run_id)

    # Parse interleaved %H / filename output.
    # git log --format=%H with --name-only interleaves:
    #   SHA\n\nfile1\nfile2\n\nSHA\n\nfile1...
    output = log_result.stdout
    entries: list[tuple[str, str]] = []  # (sha, filepath)
    current_sha: str | None = None
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if len(line) == 40 and all(c in "0123456789abcdef" for c in line):
            current_sha = line
        elif current_sha:
            entries.append((current_sha, line))

    # Step 4: cap check (count distinct commits).
    #
    # Bug jade-cabin-tithe (Parts 1+2): the cap value is read from the
    # BRIDGE_COMMIT_CAP environment variable when set, falling back to the
    # caller's `cap` argument (default 500) otherwise. Malformed values fall
    # back to the default — operators should never see the bridge silently
    # crash on a typo'd env var.
    #
    # Cap-exceeded behavior is split into three lanes:
    #   * effective_cap == 0  → fail-loud (preserve the 5566-685e/6d94-5cba
    #                            contract; explicit operator opt-in).
    #   * cold-start          → BRIDGE_ALERT + seed_at_head (unchanged; an
    #                            unbounded historical backfill is never wanted).
    #   * normal run          → CHUNKED-ADVANCE: process the first
    #                            `effective_cap` chronological commits in this
    #                            run, return their events to the caller, and
    #                            let the caller's deferred-cursor-write logic
    #                            advance the cursor to the chunk's HEAD once
    #                            every event has been successfully processed.
    #                            Subsequent cron ticks pick up where the chunk
    #                            left off (eventual consistency).
    #
    # NO-SILENT-DROP INVARIANT (5566-685e): the chunked path NEVER drops an
    # event. Every event in cursor..chunk_HEAD is returned to the caller before
    # the cursor is advanced. The caller (process_events) only writes the
    # cursor when len(events) processed equals the chunk size — preserving the
    # deferred-write semantics. Future maintainers: do NOT "harden" this by
    # restoring the old `raise` — that change reintroduces the production stall
    # bug jade-cabin-tithe was filed to fix.
    raw_cap = os.environ.get("BRIDGE_COMMIT_CAP")
    if raw_cap is not None and raw_cap.strip() != "":
        try:
            effective_cap = int(raw_cap)
        except ValueError:
            logger.warning(
                "_outbound_cursor: BRIDGE_COMMIT_CAP=%r is not an int — "
                "falling back to default cap=%d",
                raw_cap,
                cap,
            )
            effective_cap = cap
    else:
        effective_cap = cap

    distinct_shas = {sha for sha, _ in entries}
    if len(distinct_shas) > effective_cap:
        write_cursor_bridge_alert(
            tracker_path,
            reason=(
                f"{len(distinct_shas)}-commit cap exceeded (cap={effective_cap}): "
                "chunking" if effective_cap > 0 else
                f"{len(distinct_shas)}-commit cap exceeded: seeding at HEAD"
            ),
            bridge_env_id=bridge_env_id,
        )
        if cursor_sha is None:
            # Cold-start: seed at HEAD to skip unbounded historical backfill.
            # Use workflow_dispatch with backfill=true to recover historical events.
            logger.warning(
                "_outbound_cursor: cold-start %d commits exceed cap %d — seeding at HEAD",
                len(distinct_shas),
                effective_cap,
            )
            return _seed_at_head(tracker_path, bridge_env_id, run_id)
        if effective_cap == 0:
            # Explicit operator opt-in to fail-loud (5566-685e / 6d94-5cba).
            logger.error(
                "_outbound_cursor: %d commits exceed cap 0 (fail-loud mode) — "
                "aborting run; cursor NOT advanced",
                len(distinct_shas),
            )
            raise RuntimeError(
                f"{len(distinct_shas)} commits exceed cap 0. "
                "BRIDGE_COMMIT_CAP=0 selects fail-loud mode; unset or raise "
                "BRIDGE_COMMIT_CAP to switch to chunked-advance, or run the "
                "outbound bridge with backfill=true to sync unprocessed events."
            )
        # Normal run, chunked-advance: keep only entries belonging to the
        # chronologically-earliest `effective_cap` commits.
        #
        # git log emits commits in reverse-chronological order, so reverse the
        # entry list to walk oldest-first and pick the first effective_cap
        # distinct SHAs we encounter. This preserves per-event ordering within
        # each commit while bounding the chunk size at the commit level.
        chunk_shas: list[str] = []
        seen: set[str] = set()
        for sha, _ in reversed(entries):
            if sha not in seen:
                seen.add(sha)
                chunk_shas.append(sha)
                if len(chunk_shas) >= effective_cap:
                    break
        chunk_sha_set = set(chunk_shas)
        # Re-emit entries in chronological (oldest-first) order so callers
        # observe events in the same order they were committed. This matters
        # for chunked-advance: the caller's cursor advances after every
        # successfully processed event, so processing oldest-first bounds
        # the worst-case "events not yet processed" set to the failing event
        # onward. Downstream sort_events_for_dispatch still re-orders by
        # ticket_id + type_priority within a sort group.
        entries = [(s, p) for (s, p) in reversed(entries) if s in chunk_sha_set]
        logger.info(
            "_outbound_cursor: %d commits exceed cap %d — chunking to "
            "%d earliest commits (cursor will advance only after caller "
            "processes every event)",
            len(distinct_shas),
            effective_cap,
            len(chunk_shas),
        )

    # Build event dicts from file paths.
    # git log emits paths relative to the repo root. When the tracker is mounted
    # as a worktree at `.tickets-tracker/`, those relative paths are  # tickets-boundary-ok: comment
    # `<ticket-id>/<ts>-<uuid>-<EVENT>.json` — no `.tickets-tracker/` prefix.  # tickets-boundary-ok: comment
    # The existing _EVENT_FILE_RE expects that prefix, so we use a relative
    # pattern here and fall back to the existing absolute/prefixed patterns for
    # robustness (e.g. when callers pre-prefix paths).
    import re  # noqa: PLC0415

    from bridge._outbound_api import (  # noqa: PLC0415
        _EVENT_FILE_ABS_RE,
        _EVENT_FILE_RE,
    )

    _EVENT_FILE_REL_RE = re.compile(
        r"^([^/]+)/(\d+)-([0-9a-f-]+)-([A-Z][A-Z_]*)\.json$"
    )

    events: list[dict[str, Any]] = []
    for sha, filepath in entries:
        match = _EVENT_FILE_RE.match(filepath)
        is_rel = False
        if not match and filepath.startswith("/"):
            match = _EVENT_FILE_ABS_RE.match(filepath)
        if not match:
            match = _EVENT_FILE_REL_RE.match(filepath)
            is_rel = match is not None
        if match:
            ticket_id = match.group(1)
            event_type = match.group(4)
            resolved_path = str(tracker_path / filepath) if is_rel else filepath
            events.append(
                {
                    "ticket_id": ticket_id,
                    "event_type": event_type,
                    "file_path": resolved_path,
                    "commit_sha": sha,
                }
            )

    return events
