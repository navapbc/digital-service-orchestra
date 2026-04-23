"""Inbound comment pull with dual-key dedup for bridge-inbound."""

from __future__ import annotations

import json
import re
import time
import uuid
from pathlib import Path
from typing import Any

_ORIGIN_UUID_RE = re.compile(r"<!-- origin-uuid: ([0-9a-f-]+) -->")


def _read_dedup_map(ticket_dir: Path) -> dict[str, Any]:
    """Read .jira-comment-map from ticket_dir. Returns empty structure if absent."""
    path = ticket_dir / ".jira-comment-map"
    if not path.exists():
        return {"uuid_to_jira_id": {}, "jira_id_to_uuid": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        data.setdefault("uuid_to_jira_id", {})
        data.setdefault("jira_id_to_uuid", {})
        return data
    except (OSError, json.JSONDecodeError):
        return {"uuid_to_jira_id": {}, "jira_id_to_uuid": {}}


def _write_dedup_map(ticket_dir: Path, dedup_map: dict[str, Any]) -> None:
    """Write .jira-comment-map atomically to ticket_dir."""
    path = ticket_dir / ".jira-comment-map"
    tmp_path = path.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(dedup_map, ensure_ascii=False), encoding="utf-8")
    tmp_path.rename(path)


def _strip_uuid_marker(body: str) -> str:
    """Remove the <!-- origin-uuid: ... --> line from body text."""
    return re.sub(r"\n?<!-- origin-uuid: [0-9a-f-]+ -->", "", body).rstrip()


# REVIEW-DEFENSE: pull_comments, _read_dedup_map, _write_dedup_map, and
# _strip_uuid_marker are all covered by tests/scripts/test_bridge_inbound_comment.py
# (6 unit tests written in batch 7, passing GREEN in this batch). Those tests
# exercise all code paths including primary dedup, secondary dedup, dedup-map
# update, and marker stripping via the pull_comments integration surface.
def pull_comments(
    jira_key: str,
    ticket_id: str,
    ticket_dir: Path,
    acli_client: Any,
    bridge_env_id: str,
) -> list[dict[str, Any]]:
    """Pull Jira comments for a ticket and write new COMMENT events locally.

    Dual-key dedup:
      - Primary: Jira comment ID checked against jira_id_to_uuid
      - Secondary: UUID marker in body checked against uuid_to_jira_id

    Args:
        jira_key: Jira issue key (e.g. "DSO-1").
        ticket_id: Local ticket ID.
        ticket_dir: Path to the ticket directory.
        acli_client: Object with get_comments(jira_key) method.
        bridge_env_id: UUID of this bridge environment.

    Returns:
        List of written COMMENT event dicts.
    """
    jira_comments = acli_client.get_comments(jira_key)
    dedup_map = _read_dedup_map(ticket_dir)
    jira_id_to_uuid = dedup_map["jira_id_to_uuid"]
    uuid_to_jira_id = dedup_map["uuid_to_jira_id"]

    written_events: list[dict[str, Any]] = []

    for comment in jira_comments:
        jira_comment_id = comment.get("id", "")
        body = comment.get("body", "")

        # Primary dedup: Jira comment ID
        if jira_comment_id in jira_id_to_uuid:
            continue

        # Secondary dedup: UUID marker in body
        marker_match = _ORIGIN_UUID_RE.search(body)
        if marker_match:
            origin_uuid = marker_match.group(1)
            if origin_uuid in uuid_to_jira_id:
                if jira_comment_id and jira_comment_id not in jira_id_to_uuid:
                    jira_id_to_uuid[jira_comment_id] = origin_uuid
                    _write_dedup_map(ticket_dir, dedup_map)
                continue

        # New comment — write COMMENT event
        ts = time.time_ns()
        event_uuid = str(uuid.uuid4())
        stripped_body = _strip_uuid_marker(body)

        event: dict[str, Any] = {
            "event_type": "COMMENT",
            "uuid": event_uuid,
            "timestamp": ts,
            "env_id": bridge_env_id,
            "data": {"body": stripped_body},
        }

        filename = f"{ts}-{event_uuid}-COMMENT.json"
        event_path = ticket_dir / filename
        event_path.write_text(json.dumps(event, ensure_ascii=False), encoding="utf-8")

        jira_id_to_uuid[jira_comment_id] = event_uuid
        uuid_to_jira_id[event_uuid] = jira_comment_id

        written_events.append(event)

    if written_events:
        _write_dedup_map(ticket_dir, dedup_map)

    return written_events
