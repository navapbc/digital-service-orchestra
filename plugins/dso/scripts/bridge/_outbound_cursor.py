"""SHA-based checkpoint cursor for the outbound bridge.

Stores the last-processed commit SHA so the bridge processes all new events
since the previous run, not just those in HEAD~1..HEAD.
"""

from __future__ import annotations

import json
import logging
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
    if cursor_sha is None:
        logger.info("_outbound_cursor: cold-start — seeding at HEAD")
        return _seed_at_head(tracker_path, bridge_env_id, run_id)

    # Step 1: widen shallow clone (best-effort; ignore failures e.g. local-only repos)
    subprocess.run(
        ["git", "-C", str(tracker_path), "fetch", "--deepen=50", "origin", "tickets"],
        capture_output=True,
        check=False,
    )

    def _run_git_log(cursor: str) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
        return subprocess.run(
            [
                "git",
                "-C",
                str(tracker_path),
                "log",
                "--diff-filter=A",
                "--name-only",
                "--format=%H",
                f"{cursor}..HEAD",
            ],
            capture_output=True,
            text=True,
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

    # Step 4: cap check (count distinct commits)
    distinct_shas = {sha for sha, _ in entries}
    if len(distinct_shas) > cap:
        logger.warning(
            "_outbound_cursor: %d commits exceed cap %d — seeding at HEAD",
            len(distinct_shas),
            cap,
        )
        write_cursor_bridge_alert(
            tracker_path,
            reason=f"{len(distinct_shas)}-commit cap exceeded: seeding at HEAD",
            bridge_env_id=bridge_env_id,
        )
        return _seed_at_head(tracker_path, bridge_env_id, run_id)

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
        if not match and filepath.startswith("/"):
            match = _EVENT_FILE_ABS_RE.match(filepath)
        if not match:
            match = _EVENT_FILE_REL_RE.match(filepath)
        if match:
            ticket_id = match.group(1)
            event_type = match.group(4)
            events.append(
                {
                    "ticket_id": ticket_id,
                    "event_type": event_type,
                    "file_path": filepath,
                    "commit_sha": sha,
                }
            )

    return events
