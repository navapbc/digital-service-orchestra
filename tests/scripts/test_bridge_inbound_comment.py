"""RED tests for bridge-inbound.py inbound comment pull and dedup.

These tests are RED — they test functionality that does not yet exist.
All test functions must FAIL before bridge-inbound.py is implemented.

The bridge-inbound module is expected to expose:

    pull_comments(
        jira_key: str,
        ticket_id: str,
        ticket_dir: Path,
        acli_client: Any,
        bridge_env_id: str,
    ) -> list[dict[str, Any]]:
        Pull Jira comments for a ticket and write new COMMENT events locally.
        Returns list of written COMMENT event dicts.

Dedup contract: plugins/dso/docs/contracts/comment-sync-dedup.md
  - Primary dedup key: Jira comment ID (checked against jira_id_to_uuid in
    .tickets-tracker/<ticket-id>/.jira-comment-map)
  - Secondary dedup key: UUID marker (<!-- origin-uuid: {uuid} -->) in body,
    checked against uuid_to_jira_id (must NOT be relied on when marker absent)
  - Dedup map file path: <ticket_dir>/.jira-comment-map
  - After writing a new COMMENT event, both dicts are updated atomically.

ACLI client interface:
    acli_client.get_comments(jira_key) -> list[dict]
        Returns list of Jira comment objects with at least:
            {"id": str, "body": str}

COMMENT event format (written to ticket_dir):
    {
        "event_type": "COMMENT",
        "uuid": str,          # UUID4 of the new local event
        "timestamp": int,
        "env_id": str,        # bridge_env_id
        "data": {"body": str},
    }

Test: python3 -m pytest tests/scripts/test_bridge_inbound_comment.py
All tests must return non-zero until bridge-inbound.py is implemented.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-inbound.py"

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_UUID_LOCAL_1 = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_UUID_LOCAL_2 = "aabbccdd-1122-3344-5566-778899aabbcc"
_JIRA_COMMENT_ID_1 = "j-1"
_JIRA_COMMENT_ID_99 = "j-99"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_inbound", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def bridge() -> ModuleType:
    """Return the bridge-inbound module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"bridge-inbound.py not found at {SCRIPT_PATH} — "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_dedup_map(
    uuid_to_jira_id: dict[str, str] | None = None,
    jira_id_to_uuid: dict[str, str] | None = None,
) -> dict[str, Any]:
    return {
        "uuid_to_jira_id": uuid_to_jira_id or {},
        "jira_id_to_uuid": jira_id_to_uuid or {},
    }


def _write_dedup_map(ticket_dir: Path, dedup_map: dict[str, Any]) -> Path:
    """Write .jira-comment-map to ticket_dir and return its path."""
    path = ticket_dir / ".jira-comment-map"
    path.write_text(json.dumps(dedup_map, ensure_ascii=False))
    return path


def _read_dedup_map(ticket_dir: Path) -> dict[str, Any]:
    """Read and parse .jira-comment-map from ticket_dir."""
    path = ticket_dir / ".jira-comment-map"
    return json.loads(path.read_text(encoding="utf-8"))


def _list_comment_events(ticket_dir: Path) -> list[dict[str, Any]]:
    """Return parsed contents of all COMMENT event files in ticket_dir."""
    events = []
    for f in sorted(ticket_dir.glob("*-COMMENT.json")):
        events.append(json.loads(f.read_text(encoding="utf-8")))
    return events


def _make_acli_client(comments: list[dict[str, Any]]) -> MagicMock:
    """Return a mock ACLI client whose get_comments returns the given list."""
    client = MagicMock()
    client.get_comments = MagicMock(return_value=comments)
    return client


# ---------------------------------------------------------------------------
# Test 1: new Jira comment with no dedup entry → COMMENT event written
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_writes_comment_event_for_new_jira_comment(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a Jira comment {id: 'j-1', body: 'Hello'} not in dedup map,
    pull_comments writes a COMMENT event file in ticket_dir with
    event_type='COMMENT', env_id=bridge_env_id, data.body='Hello'.
    """
    ticket_dir = tmp_path / "w21-new"
    ticket_dir.mkdir()
    # Empty dedup map — j-1 not present
    _write_dedup_map(ticket_dir, _make_dedup_map())

    jira_comments = [{"id": _JIRA_COMMENT_ID_1, "body": "Hello"}]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-1",
        ticket_id="w21-new",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert isinstance(result, list), "pull_comments must return a list"
    assert len(result) == 1, "Must return exactly one written COMMENT event dict"

    written = result[0]
    assert written.get("event_type") == "COMMENT", (
        "Written event must have event_type='COMMENT'"
    )
    assert written.get("env_id") == _BRIDGE_ENV_ID, (
        "Written event must have env_id matching bridge_env_id"
    )
    data = written.get("data", {})
    assert data.get("body") == "Hello", (
        "Written event data.body must match Jira comment body"
    )

    # Verify a COMMENT event file was actually written to disk
    comment_files = list(ticket_dir.glob("*-COMMENT.json"))
    assert len(comment_files) == 1, (
        "Exactly one COMMENT event file must be written to disk"
    )

    disk_event = json.loads(comment_files[0].read_text(encoding="utf-8"))
    assert disk_event.get("event_type") == "COMMENT"
    assert disk_event.get("env_id") == _BRIDGE_ENV_ID
    assert disk_event.get("data", {}).get("body") == "Hello"


# ---------------------------------------------------------------------------
# Test 2: primary dedup — Jira ID already in jira_id_to_uuid → skipped
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_skips_comment_already_in_dedup_map_by_jira_id(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given Jira comment ID 'j-1' already in jira_id_to_uuid map,
    no COMMENT event is written (primary dedup key).
    """
    ticket_dir = tmp_path / "w21-dedup-primary"
    ticket_dir.mkdir()
    # j-1 already mapped to a local UUID
    dedup_map = _make_dedup_map(
        jira_id_to_uuid={_JIRA_COMMENT_ID_1: _UUID_LOCAL_1},
        uuid_to_jira_id={_UUID_LOCAL_1: _JIRA_COMMENT_ID_1},
    )
    _write_dedup_map(ticket_dir, dedup_map)

    jira_comments = [{"id": _JIRA_COMMENT_ID_1, "body": "Hello"}]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-1",
        ticket_id="w21-dedup-primary",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert result == [], (
        "pull_comments must return empty list when all comments are in dedup map"
    )
    comment_files = list(ticket_dir.glob("*-COMMENT.json"))
    assert len(comment_files) == 0, (
        "No COMMENT event file must be written when Jira ID is in dedup map (primary key)"
    )


# ---------------------------------------------------------------------------
# Test 3: secondary dedup — UUID marker in body matches uuid_to_jira_id → skipped
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_skips_local_origin_comment_with_uuid_marker(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given Jira comment body containing '<!-- origin-uuid: {uuid} -->' where
    that UUID is in uuid_to_jira_id map, no COMMENT event is written
    (secondary dedup via UUID marker).

    The Jira comment ID is NOT in jira_id_to_uuid (simulates stripped primary key
    race window — e.g. outbound pushed but dedup map write failed), so primary
    dedup would miss it; secondary dedup via marker must catch it.
    """
    ticket_dir = tmp_path / "w21-dedup-secondary"
    ticket_dir.mkdir()

    local_uuid = _UUID_LOCAL_2
    jira_comment_id = "j-2"

    # uuid_to_jira_id has the local UUID → but jira_id_to_uuid does NOT have j-2
    # (simulates the edge case where secondary dedup is the backstop)
    dedup_map = _make_dedup_map(
        uuid_to_jira_id={local_uuid: jira_comment_id},
        jira_id_to_uuid={},
    )
    _write_dedup_map(ticket_dir, dedup_map)

    # Comment body contains the UUID marker
    body = f"Some text.\n<!-- origin-uuid: {local_uuid} -->"
    jira_comments = [{"id": jira_comment_id, "body": body}]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-2",
        ticket_id="w21-dedup-secondary",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert result == [], (
        "pull_comments must return empty list when UUID marker matches uuid_to_jira_id"
    )
    comment_files = list(ticket_dir.glob("*-COMMENT.json"))
    assert len(comment_files) == 0, (
        "No COMMENT event file must be written when UUID marker dedup matches"
    )


# ---------------------------------------------------------------------------
# Test 4: marker stripped but primary Jira ID still in map → skipped
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_skips_local_origin_comment_stripped_marker_via_jira_id(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given Jira comment whose UUID marker was stripped (body has no marker)
    but jira_id 'j-99' is in jira_id_to_uuid dedup map, no event is written
    (primary key survives stripping).

    This validates that the implementation does NOT rely solely on the UUID marker
    for dedup — the Jira comment ID (primary key) must be checked first.
    """
    ticket_dir = tmp_path / "w21-stripped-marker"
    ticket_dir.mkdir()

    # j-99 is in the primary dedup map; no marker in the body
    dedup_map = _make_dedup_map(
        jira_id_to_uuid={_JIRA_COMMENT_ID_99: _UUID_LOCAL_1},
        uuid_to_jira_id={_UUID_LOCAL_1: _JIRA_COMMENT_ID_99},
    )
    _write_dedup_map(ticket_dir, dedup_map)

    # Body has no marker (stripped by Jira rich-text editor)
    jira_comments = [{"id": _JIRA_COMMENT_ID_99, "body": "Comment without marker"}]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-99",
        ticket_id="w21-stripped-marker",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert result == [], (
        "pull_comments must return empty list when Jira ID is in dedup map, "
        "even when body UUID marker is absent (stripped)"
    )
    comment_files = list(ticket_dir.glob("*-COMMENT.json"))
    assert len(comment_files) == 0, (
        "No COMMENT event file must be written when primary dedup key matches, "
        "regardless of marker presence"
    )


# ---------------------------------------------------------------------------
# Test 5: dedup map is updated after writing a new COMMENT event
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_updates_dedup_map_after_writing_event(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """After writing a new COMMENT event, the dedup map is updated with
    jira_id_to_uuid[jira_comment_id] = new_event_uuid and
    uuid_to_jira_id[new_event_uuid] = jira_comment_id.
    """
    ticket_dir = tmp_path / "w21-update-map"
    ticket_dir.mkdir()
    # Empty dedup map
    _write_dedup_map(ticket_dir, _make_dedup_map())

    jira_comments = [{"id": _JIRA_COMMENT_ID_1, "body": "Update map test"}]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-1",
        ticket_id="w21-update-map",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert len(result) == 1, "Must write one COMMENT event"
    new_event_uuid = result[0].get("uuid")
    assert new_event_uuid is not None, "Written event must have a uuid field"

    # Read updated dedup map from disk
    updated_map = _read_dedup_map(ticket_dir)

    assert _JIRA_COMMENT_ID_1 in updated_map.get("jira_id_to_uuid", {}), (
        "jira_id_to_uuid must contain the new Jira comment ID after writing event"
    )
    assert updated_map["jira_id_to_uuid"][_JIRA_COMMENT_ID_1] == new_event_uuid, (
        "jira_id_to_uuid[jira_comment_id] must equal the new event UUID"
    )

    assert new_event_uuid in updated_map.get("uuid_to_jira_id", {}), (
        "uuid_to_jira_id must contain the new event UUID after writing event"
    )
    assert updated_map["uuid_to_jira_id"][new_event_uuid] == _JIRA_COMMENT_ID_1, (
        "uuid_to_jira_id[new_event_uuid] must equal the Jira comment ID"
    )


# ---------------------------------------------------------------------------
# Test 6: all comments in dedup map → returns empty list
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_returns_empty_list_when_no_new_comments(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """All Jira comments are already in the dedup map; pull_comments returns
    an empty list and writes no COMMENT event files.
    """
    ticket_dir = tmp_path / "w21-all-deduped"
    ticket_dir.mkdir()

    # Both j-1 and j-2 already in map
    dedup_map = _make_dedup_map(
        jira_id_to_uuid={
            _JIRA_COMMENT_ID_1: _UUID_LOCAL_1,
            "j-2": _UUID_LOCAL_2,
        },
        uuid_to_jira_id={
            _UUID_LOCAL_1: _JIRA_COMMENT_ID_1,
            _UUID_LOCAL_2: "j-2",
        },
    )
    _write_dedup_map(ticket_dir, dedup_map)

    jira_comments = [
        {"id": _JIRA_COMMENT_ID_1, "body": "First comment"},
        {"id": "j-2", "body": "Second comment"},
    ]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-1",
        ticket_id="w21-all-deduped",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert result == [], (
        "pull_comments must return empty list when all Jira comments are in dedup map"
    )
    comment_files = list(ticket_dir.glob("*-COMMENT.json"))
    assert len(comment_files) == 0, (
        "No COMMENT event files must be written when all comments are already deduped"
    )


# ---------------------------------------------------------------------------
# Bug 8190-121b: inbound comment writer must use nanosecond timestamps
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_pull_comments_writes_comment_event_with_nanosecond_timestamp(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """pull_comments writes a COMMENT event whose 'timestamp' field is at
    nanosecond scale (> 1_000_000_000_000).

    This test is RED: current code in _comments_inbound.py uses int(time.time())
    which produces a seconds-scale integer (~1.7e9), well below the 1e12
    threshold. After the fix uses time.time_ns() the value will be ~1.7e18.
    """
    ticket_dir = tmp_path / "w21-ns-comment"
    ticket_dir.mkdir()
    # Empty dedup map — no prior comments
    _write_dedup_map(ticket_dir, _make_dedup_map())

    jira_comments = [{"id": "j-ns-1", "body": "Nanosecond test comment"}]
    acli_client = _make_acli_client(jira_comments)

    result = bridge.pull_comments(
        jira_key="DSO-9190",
        ticket_id="w21-ns-comment",
        ticket_dir=ticket_dir,
        acli_client=acli_client,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert len(result) == 1, "Must write exactly one COMMENT event"

    comment_files = list(ticket_dir.glob("*-COMMENT.json"))
    assert len(comment_files) == 1, "Exactly one COMMENT event file must exist on disk"

    event_data = json.loads(comment_files[0].read_text(encoding="utf-8"))
    ts = event_data.get("timestamp")
    assert isinstance(ts, int), f"timestamp must be an int, got {type(ts).__name__}"
    assert ts > 1_000_000_000_000, (
        f"timestamp must be nanosecond-scale (> 1_000_000_000_000); "
        f"got {ts} — current code uses int(time.time()) which is seconds-scale (~1.7e9). "
        f"Fix: use time.time_ns() in _comments_inbound.py."
    )
