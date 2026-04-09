"""RED tests for bridge-outbound.py LINK/UNLINK event processing.

These tests are RED -- they test functionality that does not yet exist.
All test functions must FAIL before bridge-outbound.py LINK/UNLINK handlers
are implemented.

Split from test_bridge_outbound.py for maintainability (review finding).

Test: python3 -m pytest tests/scripts/test_bridge_outbound_link.py
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# Module loading -- filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-outbound.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_outbound", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def bridge() -> ModuleType:
    """Return the bridge-outbound module, failing all tests if absent (RED)."""
    if not SCRIPT_PATH.exists():
        pytest.fail(
            f"bridge-outbound.py not found at {SCRIPT_PATH} -- "
            "this is expected RED state; implement the script to make tests pass."
        )
    return _load_module()


# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_UUID1 = "3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c"
_UUID3 = "deadbeef-dead-beef-dead-beefdeadbeef"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write_link_event(
    ticket_dir: Path,
    timestamp: int,
    uuid: str,
    event_type: str,
    source_id: str,
    target_id: str,
    relation: str = "relates_to",
    env_id: str = _OTHER_ENV_ID,
) -> Path:
    """Write a LINK or UNLINK event JSON file and return its path."""
    filename = f"{timestamp}-{uuid}-{event_type}.json"
    payload = {
        "timestamp": timestamp,
        "uuid": uuid,
        "event_type": event_type,
        "env_id": env_id,
        "author": "Test User",
        "data": {
            "source_id": source_id,
            "target_id": target_id,
            "relation": relation,
        },
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _write_sync_for(
    ticket_dir: Path, jira_key: str, local_id: str, ts: int = 1742605000
) -> None:
    """Write a minimal SYNC event so process_outbound can resolve the Jira key."""
    sync_payload = {
        "event_type": "SYNC",
        "jira_key": jira_key,
        "local_id": local_id,
        "env_id": _BRIDGE_ENV_ID,
        "timestamp": ts,
        "run_id": "test-run-1",
    }
    (ticket_dir / f"{ts}-{_UUID3}-SYNC.json").write_text(json.dumps(sync_payload))


# ---------------------------------------------------------------------------
# LINK test 1: relates_to LINK -> calls set_relationship
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_relates_to_calls_set_relationship(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event with relation='relates_to' and both tickets having SYNC files,
    when process_outbound is called,
    then acli_client.set_relationship() is called with the source and target Jira keys.
    """
    src_dir = tmp_path / "src-0001"
    tgt_dir = tmp_path / "tgt-0002"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-10", "src-0001", ts=1742605000)
    _write_sync_for(tgt_dir, "DSO-20", "tgt-0002", ts=1742605000)

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605100,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-0001",
        target_id="tgt-0002",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-0001",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.set_relationship.assert_called_once()
    call_args = mock_client.set_relationship.call_args
    assert "DSO-10" in call_args[0] or call_args[1].get("from_key") == "DSO-10", (
        "set_relationship must be called with source Jira key DSO-10"
    )
    assert "DSO-20" in call_args[0] or call_args[1].get("to_key") == "DSO-20", (
        "set_relationship must be called with target Jira key DSO-20"
    )


# ---------------------------------------------------------------------------
# LINK test 2: name-based link type validation via get_issue_link_types
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_validates_link_type_via_get_issue_link_types(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event with relation='relates_to',
    when process_outbound is called,
    then acli_client.get_issue_link_types() is called to confirm 'Relates' type exists.
    """
    src_dir = tmp_path / "src-0003"
    tgt_dir = tmp_path / "tgt-0004"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-30", "src-0003")
    _write_sync_for(tgt_dir, "DSO-40", "tgt-0004")

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605200,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-0003",
        target_id="tgt-0004",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-0003",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.get_issue_link_types.call_count > 0, (
        "get_issue_link_types must be called to validate available link types"
    )


# ---------------------------------------------------------------------------
# LINK test 3: link type caching -- get_issue_link_types called once per run
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_type_caching_calls_get_issue_link_types_once(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given two LINK events processed in the same process_outbound call,
    when process_outbound is called,
    then acli_client.get_issue_link_types() is called exactly once (cached result reused).
    """
    src_a_dir = tmp_path / "src-a001"
    tgt_a_dir = tmp_path / "tgt-a002"
    src_b_dir = tmp_path / "src-b001"
    tgt_b_dir = tmp_path / "tgt-b002"
    for d in [src_a_dir, tgt_a_dir, src_b_dir, tgt_b_dir]:
        d.mkdir()

    _write_sync_for(src_a_dir, "DSO-51", "src-a001")
    _write_sync_for(tgt_a_dir, "DSO-52", "tgt-a002")
    _write_sync_for(src_b_dir, "DSO-53", "src-b001")
    _write_sync_for(tgt_b_dir, "DSO-54", "tgt-b002")

    link_file_a = _write_link_event(
        src_a_dir,
        timestamp=1742605300,
        uuid="aaaa0001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="src-a001",
        target_id="tgt-a002",
        relation="relates_to",
    )
    link_file_b = _write_link_event(
        src_b_dir,
        timestamp=1742605301,
        uuid="bbbb0001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="src-b001",
        target_id="tgt-b002",
        relation="relates_to",
    )

    events = [
        {"ticket_id": "src-a001", "event_type": "LINK", "file_path": str(link_file_a)},
        {"ticket_id": "src-b001", "event_type": "LINK", "file_path": str(link_file_b)},
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.get_issue_link_types.call_count == 1, (
        "get_issue_link_types must be called exactly once per sync run (result cached)"
    )


# ---------------------------------------------------------------------------
# LINK test 4: pre-create dedup -- existing Relates link -> skip creation
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_skips_creation_when_relates_link_already_exists(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event for (DSO-10, DSO-20) and get_issue_links() already
    returns a Relates link between those two endpoints,
    when process_outbound is called,
    then set_relationship() is NOT called (dedup prevents duplicate creation).
    """
    src_dir = tmp_path / "src-dedup1"
    tgt_dir = tmp_path / "tgt-dedup2"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-10", "src-dedup1")
    _write_sync_for(tgt_dir, "DSO-20", "tgt-dedup2")

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605400,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-dedup1",
        target_id="tgt-dedup2",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-dedup1",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    # Existing link between DSO-10 and DSO-20
    mock_client.get_issue_links = MagicMock(
        return_value=[
            {
                "type": {"name": "Relates"},
                "outwardIssue": {"key": "DSO-20"},
                "inwardIssue": None,
            }
        ]
    )
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 0, (
        "set_relationship must NOT be called when a Relates link already exists between the endpoints"
    )


# ---------------------------------------------------------------------------
# LINK test 5: reciprocal dedup -- A->B and B->A -> only one Jira link created
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_reciprocal_dedup_creates_only_one_jira_link(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given LINK events for both (A->B) and (B->A) with the same relates_to relation,
    when process_outbound is called,
    then set_relationship() is called exactly once (second is deduped by checking
    existing links after the first is created).
    """
    a_dir = tmp_path / "ticket-a"
    b_dir = tmp_path / "ticket-b"
    a_dir.mkdir()
    b_dir.mkdir()

    _write_sync_for(a_dir, "DSO-100", "ticket-a")
    _write_sync_for(b_dir, "DSO-200", "ticket-b")

    link_a_to_b = _write_link_event(
        a_dir,
        timestamp=1742605500,
        uuid="cccc0001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="ticket-a",
        target_id="ticket-b",
        relation="relates_to",
    )
    link_b_to_a = _write_link_event(
        b_dir,
        timestamp=1742605501,
        uuid="cccc0002-0000-0000-0000-000000000002",
        event_type="LINK",
        source_id="ticket-b",
        target_id="ticket-a",
        relation="relates_to",
    )

    events = [
        {"ticket_id": "ticket-a", "event_type": "LINK", "file_path": str(link_a_to_b)},
        {"ticket_id": "ticket-b", "event_type": "LINK", "file_path": str(link_b_to_a)},
    ]

    # First call returns empty; second call returns the link created by first
    call_count = {"n": 0}

    def get_links_side_effect(jira_key: str) -> list:
        call_count["n"] += 1
        if call_count["n"] > 1:
            return [
                {
                    "type": {"name": "Relates"},
                    "outwardIssue": {"key": "DSO-200"},
                    "inwardIssue": None,
                }
            ]
        return []

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(side_effect=get_links_side_effect)
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 1, (
        "set_relationship must be called exactly once for reciprocal A->B / B->A LINK events"
    )


# ---------------------------------------------------------------------------
# LINK test 6: graceful degradation -- Jira rejection writes bridge_alert, continues
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_jira_rejection_writes_bridge_alert_and_continues(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event where set_relationship() raises an exception (Jira rejection),
    when process_outbound is called,
    then a BRIDGE_ALERT file is written and processing continues (no exception raised).
    """
    import subprocess as _subprocess

    src_dir = tmp_path / "src-reject1"
    tgt_dir = tmp_path / "tgt-reject2"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-300", "src-reject1")
    _write_sync_for(tgt_dir, "DSO-400", "tgt-reject2")

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605600,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-reject1",
        target_id="tgt-reject2",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-reject1",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(
        side_effect=_subprocess.CalledProcessError(1, "acli", stderr="Jira rejection")
    )

    # Must not raise
    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    alert_files = list(src_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) >= 1, (
        "A BRIDGE_ALERT file must be written when set_relationship() raises an exception"
    )


# ---------------------------------------------------------------------------
# LINK test 7: missing source SYNC -> skip event (no set_relationship call)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_missing_source_sync_skips_event(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event where the source ticket has no SYNC file (no Jira key),
    when process_outbound is called,
    then set_relationship() is NOT called and no exception is raised.
    """
    src_dir = tmp_path / "src-nosync"
    tgt_dir = tmp_path / "tgt-hassync"
    src_dir.mkdir()
    tgt_dir.mkdir()

    # Source has no SYNC -- target does
    _write_sync_for(tgt_dir, "DSO-500", "tgt-hassync")

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605700,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-nosync",
        target_id="tgt-hassync",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-nosync",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 0, (
        "set_relationship must NOT be called when source ticket has no SYNC (no Jira key)"
    )


# ---------------------------------------------------------------------------
# LINK test 8: missing target SYNC -> bridge_alert, skip
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_missing_target_sync_writes_bridge_alert(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event where the target ticket has no SYNC file (no Jira key),
    when process_outbound is called,
    then a BRIDGE_ALERT is written and set_relationship() is NOT called.
    """
    src_dir = tmp_path / "src-has-sync"
    tgt_dir = tmp_path / "tgt-no-sync"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-600", "src-has-sync")
    # Target has no SYNC

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605800,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-has-sync",
        target_id="tgt-no-sync",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-has-sync",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 0, (
        "set_relationship must NOT be called when target ticket has no SYNC"
    )
    alert_files = list(src_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) >= 1, (
        "A BRIDGE_ALERT must be written when the target SYNC is missing"
    )


# ---------------------------------------------------------------------------
# LINK test 9: link type not found -> bridge_alert with available types, skip
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_type_not_found_writes_bridge_alert_with_available_types(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event with relation='relates_to' but get_issue_link_types()
    returns no 'Relates' type (only 'Blocks' is available),
    when process_outbound is called,
    then a BRIDGE_ALERT is written (mentioning available types) and
    set_relationship() is NOT called.
    """
    src_dir = tmp_path / "src-notype"
    tgt_dir = tmp_path / "tgt-notype"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-700", "src-notype")
    _write_sync_for(tgt_dir, "DSO-800", "tgt-notype")

    link_file = _write_link_event(
        src_dir,
        timestamp=1742605900,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-notype",
        target_id="tgt-notype",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-notype",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    # Only "Blocks" available -- no "Relates"
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 0, (
        "set_relationship must NOT be called when the required link type is not found"
    )
    alert_files = list(src_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) >= 1, (
        "A BRIDGE_ALERT must be written when the link type is not found in Jira"
    )
    # Verify alert mentions available types
    alert_data = json.loads(alert_files[0].read_text())
    reason = alert_data.get("data", {}).get("reason", "")
    assert "Blocks" in reason or "available" in reason.lower(), (
        "BRIDGE_ALERT reason must mention available link types"
    )


# ---------------------------------------------------------------------------
# LINK test 10: non-relates_to LINK events -> filtered out
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_non_relates_to_relation_is_filtered_out(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a LINK event with relation='blocks' (not 'relates_to'),
    when process_outbound is called,
    then set_relationship() is NOT called (only relates_to is processed).
    """
    src_dir = tmp_path / "src-blocks"
    tgt_dir = tmp_path / "tgt-blocks"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-900", "src-blocks")
    _write_sync_for(tgt_dir, "DSO-901", "tgt-blocks")

    link_file = _write_link_event(
        src_dir,
        timestamp=1742606000,
        uuid=_UUID1,
        event_type="LINK",
        source_id="src-blocks",
        target_id="tgt-blocks",
        relation="blocks",  # NOT relates_to
    )

    events = [
        {
            "ticket_id": "src-blocks",
            "event_type": "LINK",
            "file_path": str(link_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"},
            {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 0, (
        "set_relationship must NOT be called for non-relates_to LINK events (only relates_to is supported)"
    )


# ---------------------------------------------------------------------------
# UNLINK test 11: UNLINK -> read-before-delete: get_issue_links, match endpoints, delete
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_calls_get_issue_links_then_delete_specific_link(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event for (src->tgt) and get_issue_links returns a matching link,
    when process_outbound is called,
    then get_issue_links() is called first, then delete_issue_link() is called for
    the matching link ID.
    """
    src_dir = tmp_path / "src-unlink1"
    tgt_dir = tmp_path / "tgt-unlink1"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1010", "src-unlink1")
    _write_sync_for(tgt_dir, "DSO-1020", "tgt-unlink1")

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606100,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-unlink1",
        target_id="tgt-unlink1",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-unlink1",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(
        return_value=[
            {
                "id": "link-id-001",
                "type": {"name": "Relates"},
                "outwardIssue": {"key": "DSO-1020"},
                "inwardIssue": None,
            }
        ]
    )
    mock_client.delete_issue_link = MagicMock(return_value={"status": "deleted"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.get_issue_links.call_count > 0, (
        "get_issue_links must be called before deleting (read-before-delete)"
    )
    mock_client.delete_issue_link.assert_called_once_with("link-id-001")


# ---------------------------------------------------------------------------
# UNLINK test 12: wrong target endpoint -> no delete
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_wrong_target_endpoint_does_not_delete(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event for (src->tgt) but get_issue_links returns a link
    to a different target (DSO-9999, not DSO-1020),
    when process_outbound is called,
    then delete_issue_link() is NOT called (endpoint matching prevents wrong deletion).
    """
    src_dir = tmp_path / "src-wrongtgt"
    tgt_dir = tmp_path / "tgt-wrongtgt"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1030", "src-wrongtgt")
    _write_sync_for(tgt_dir, "DSO-1040", "tgt-wrongtgt")

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606200,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-wrongtgt",
        target_id="tgt-wrongtgt",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-wrongtgt",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    # Link exists but points to DSO-9999, not DSO-1040
    mock_client.get_issue_links = MagicMock(
        return_value=[
            {
                "id": "link-id-999",
                "type": {"name": "Relates"},
                "outwardIssue": {"key": "DSO-9999"},
                "inwardIssue": None,
            }
        ]
    )
    mock_client.delete_issue_link = MagicMock(return_value={"status": "deleted"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.delete_issue_link.call_count == 0, (
        "delete_issue_link must NOT be called when no link matches the target endpoint"
    )


# ---------------------------------------------------------------------------
# UNLINK test 13: 404 on source issue -> "already gone", no error
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_404_on_source_issue_is_treated_as_already_gone(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event where get_issue_links() raises a 404-like error
    (source issue not found in Jira),
    when process_outbound is called,
    then no exception is raised (treated as 'already gone') and
    delete_issue_link() is NOT called.
    """
    import subprocess as _subprocess

    src_dir = tmp_path / "src-404"
    tgt_dir = tmp_path / "tgt-404"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1050", "src-404")
    _write_sync_for(tgt_dir, "DSO-1060", "tgt-404")

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606300,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-404",
        target_id="tgt-404",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-404",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    # Simulate 404: source issue not found
    mock_client.get_issue_links = MagicMock(
        side_effect=_subprocess.CalledProcessError(
            404,
            "acli",
            stderr="Issue does not exist or you do not have permission to see it",
        )
    )
    mock_client.delete_issue_link = MagicMock(return_value={"status": "deleted"})

    # Must not raise
    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.delete_issue_link.call_count == 0, (
        "delete_issue_link must NOT be called when source issue returns 404 (already gone)"
    )


# ---------------------------------------------------------------------------
# UNLINK test 14: Jira rejection on delete -> bridge_alert, continues
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_jira_rejection_on_delete_writes_bridge_alert_and_continues(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event where delete_issue_link() raises an exception
    (Jira rejection, not a 404),
    when process_outbound is called,
    then a BRIDGE_ALERT is written and no exception is raised (processing continues).
    """
    import subprocess as _subprocess

    src_dir = tmp_path / "src-del-fail"
    tgt_dir = tmp_path / "tgt-del-fail"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1070", "src-del-fail")
    _write_sync_for(tgt_dir, "DSO-1080", "tgt-del-fail")

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606400,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-del-fail",
        target_id="tgt-del-fail",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-del-fail",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(
        return_value=[
            {
                "id": "link-id-del-fail",
                "type": {"name": "Relates"},
                "outwardIssue": {"key": "DSO-1080"},
                "inwardIssue": None,
            }
        ]
    )
    mock_client.delete_issue_link = MagicMock(
        side_effect=_subprocess.CalledProcessError(
            500, "acli", stderr="Internal server error"
        )
    )

    # Must not raise
    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    alert_files = list(src_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) >= 1, (
        "A BRIDGE_ALERT must be written when delete_issue_link() fails with a Jira error"
    )


# ---------------------------------------------------------------------------
# UNLINK test 15: concurrent modification (404/409 on delete) -> "already gone"
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_concurrent_modification_404_or_409_treated_as_already_gone(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event where delete_issue_link() raises a 404 or 409 error
    (link was already deleted by a concurrent process),
    when process_outbound is called,
    then no exception is raised and no BRIDGE_ALERT is written
    (concurrent deletion is idempotent, treated as success).
    """
    import subprocess as _subprocess

    src_dir = tmp_path / "src-concurrent"
    tgt_dir = tmp_path / "tgt-concurrent"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1090", "src-concurrent")
    _write_sync_for(tgt_dir, "DSO-1091", "tgt-concurrent")

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606500,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-concurrent",
        target_id="tgt-concurrent",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-concurrent",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(
        return_value=[
            {
                "id": "link-id-concurrent",
                "type": {"name": "Relates"},
                "outwardIssue": {"key": "DSO-1091"},
                "inwardIssue": None,
            }
        ]
    )
    # Simulate 404 on delete -- link already gone
    mock_client.delete_issue_link = MagicMock(
        side_effect=_subprocess.CalledProcessError(404, "acli", stderr="Link not found")
    )

    # Must not raise
    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # No BRIDGE_ALERT expected for concurrent deletion (already gone is success)
    alert_files = list(src_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files) == 0, (
        "No BRIDGE_ALERT should be written when delete_issue_link returns 404/409 "
        "(concurrent deletion treated as already-gone success)"
    )


# ---------------------------------------------------------------------------
# UNLINK test 16: non-relates_to UNLINK events -> filtered out
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_non_relates_to_relation_is_filtered_out(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event with relation='blocks' (not 'relates_to'),
    when process_outbound is called,
    then delete_issue_link() is NOT called (only relates_to is processed).
    """
    src_dir = tmp_path / "src-unlink-blocks"
    tgt_dir = tmp_path / "tgt-unlink-blocks"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1100", "src-unlink-blocks")
    _write_sync_for(tgt_dir, "DSO-1110", "tgt-unlink-blocks")

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606600,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-unlink-blocks",
        target_id="tgt-unlink-blocks",
        relation="blocks",  # NOT relates_to
    )

    events = [
        {
            "ticket_id": "src-unlink-blocks",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"},
            {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.delete_issue_link = MagicMock(return_value={"status": "deleted"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.delete_issue_link.call_count == 0, (
        "delete_issue_link must NOT be called for non-relates_to UNLINK events"
    )


# ---------------------------------------------------------------------------
# UNLINK test 17: missing source/target SYNC -> skip
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_unlink_missing_source_and_target_sync_skips_event(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given an UNLINK event where neither source nor target ticket has a SYNC file,
    when process_outbound is called,
    then delete_issue_link() is NOT called and no exception is raised.
    """
    src_dir = tmp_path / "src-both-nosync"
    tgt_dir = tmp_path / "tgt-both-nosync"
    src_dir.mkdir()
    tgt_dir.mkdir()

    # Neither has a SYNC file

    unlink_file = _write_link_event(
        src_dir,
        timestamp=1742606700,
        uuid=_UUID1,
        event_type="UNLINK",
        source_id="src-both-nosync",
        target_id="tgt-both-nosync",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-both-nosync",
            "event_type": "UNLINK",
            "file_path": str(unlink_file),
        }
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.delete_issue_link = MagicMock(return_value={"status": "deleted"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.delete_issue_link.call_count == 0, (
        "delete_issue_link must NOT be called when both source and target tickets lack SYNC files"
    )


# ---------------------------------------------------------------------------
# Dedup test 18: duplicate LINK events for same (src, tgt, relates_to)
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_duplicate_events_do_not_create_duplicate_jira_links(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given two LINK events for the same (source, target, relates_to) triple
    in the same process_outbound call,
    when process_outbound is called,
    then set_relationship() is called exactly once (dedup prevents duplicate links).
    """
    src_dir = tmp_path / "src-dup-link"
    tgt_dir = tmp_path / "tgt-dup-link"
    src_dir.mkdir()
    tgt_dir.mkdir()

    _write_sync_for(src_dir, "DSO-1200", "src-dup-link")
    _write_sync_for(tgt_dir, "DSO-1210", "tgt-dup-link")

    link_file_1 = _write_link_event(
        src_dir,
        timestamp=1742606800,
        uuid="dddd0001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="src-dup-link",
        target_id="tgt-dup-link",
        relation="relates_to",
    )
    link_file_2 = _write_link_event(
        src_dir,
        timestamp=1742606801,
        uuid="dddd0002-0000-0000-0000-000000000002",
        event_type="LINK",
        source_id="src-dup-link",
        target_id="tgt-dup-link",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-dup-link",
            "event_type": "LINK",
            "file_path": str(link_file_1),
        },
        {
            "ticket_id": "src-dup-link",
            "event_type": "LINK",
            "file_path": str(link_file_2),
        },
    ]

    # After first creation, return the link on subsequent get_issue_links calls
    call_count = {"n": 0}

    def get_links_side_effect(jira_key: str) -> list:
        call_count["n"] += 1
        if call_count["n"] > 1:
            return [
                {
                    "id": "link-id-dup",
                    "type": {"name": "Relates"},
                    "outwardIssue": {"key": "DSO-1210"},
                    "inwardIssue": None,
                }
            ]
        return []

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(side_effect=get_links_side_effect)
    mock_client.set_relationship = MagicMock(return_value={"status": "created"})

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert mock_client.set_relationship.call_count == 1, (
        "set_relationship must be called exactly once even for duplicate LINK events "
        "(dedup prevents duplicate Jira links)"
    )


# ---------------------------------------------------------------------------
# Degradation test 19: multiple Jira failures -> each writes bridge_alert, none blocks others
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_multiple_jira_failures_each_write_bridge_alert_independently(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given two LINK events that both fail at set_relationship() (Jira rejections),
    when process_outbound is called,
    then both events produce a BRIDGE_ALERT and no exception is raised
    (each failure is isolated -- one does not block the other).
    """
    import subprocess as _subprocess

    src_a_dir = tmp_path / "src-fail-a"
    tgt_a_dir = tmp_path / "tgt-fail-a"
    src_b_dir = tmp_path / "src-fail-b"
    tgt_b_dir = tmp_path / "tgt-fail-b"
    for d in [src_a_dir, tgt_a_dir, src_b_dir, tgt_b_dir]:
        d.mkdir()

    _write_sync_for(src_a_dir, "DSO-1300", "src-fail-a")
    _write_sync_for(tgt_a_dir, "DSO-1310", "tgt-fail-a")
    _write_sync_for(src_b_dir, "DSO-1320", "src-fail-b")
    _write_sync_for(tgt_b_dir, "DSO-1330", "tgt-fail-b")

    link_file_a = _write_link_event(
        src_a_dir,
        timestamp=1742606900,
        uuid="eeee0001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="src-fail-a",
        target_id="tgt-fail-a",
        relation="relates_to",
    )
    link_file_b = _write_link_event(
        src_b_dir,
        timestamp=1742606901,
        uuid="eeee0002-0000-0000-0000-000000000002",
        event_type="LINK",
        source_id="src-fail-b",
        target_id="tgt-fail-b",
        relation="relates_to",
    )

    events = [
        {
            "ticket_id": "src-fail-a",
            "event_type": "LINK",
            "file_path": str(link_file_a),
        },
        {
            "ticket_id": "src-fail-b",
            "event_type": "LINK",
            "file_path": str(link_file_b),
        },
    ]

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(
        side_effect=_subprocess.CalledProcessError(500, "acli", stderr="Server error")
    )

    # Must not raise
    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Both failures must produce a BRIDGE_ALERT in their respective source dirs
    alert_files_a = list(src_a_dir.glob("*-BRIDGE_ALERT.json"))
    alert_files_b = list(src_b_dir.glob("*-BRIDGE_ALERT.json"))
    assert len(alert_files_a) >= 1, (
        "BRIDGE_ALERT must be written for first LINK event failure (src-fail-a)"
    )
    assert len(alert_files_b) >= 1, (
        "BRIDGE_ALERT must be written for second LINK event failure (src-fail-b) -- "
        "first failure must not block the second"
    )


# ---------------------------------------------------------------------------
# LINK test 16: timestamp ordering -- LINK/UNLINK processed in timestamp order
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_unlink_events_processed_in_timestamp_order(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a batch of LINK/UNLINK events with out-of-order timestamps [t3, t1, t2],
    when process_outbound() is called,
    then the events are processed in ascending timestamp order (t1, t2, t3),
    verified by checking the order of acli_client method calls.

    This test is RED: timestamp ordering is not yet implemented in process_outbound.
    Currently events are processed in the order they appear in the input list.
    """
    src_a_dir = tmp_path / "ts-src-a"
    tgt_a_dir = tmp_path / "ts-tgt-a"
    src_b_dir = tmp_path / "ts-src-b"
    tgt_b_dir = tmp_path / "ts-tgt-b"
    src_c_dir = tmp_path / "ts-src-c"
    tgt_c_dir = tmp_path / "ts-tgt-c"
    for d in [src_a_dir, tgt_a_dir, src_b_dir, tgt_b_dir, src_c_dir, tgt_c_dir]:
        d.mkdir()

    # Jira keys: A=earliest (t1), B=middle (t2), C=latest (t3)
    _write_sync_for(src_a_dir, "DSO-2010", "ts-src-a")
    _write_sync_for(tgt_a_dir, "DSO-2011", "ts-tgt-a")
    _write_sync_for(src_b_dir, "DSO-2020", "ts-src-b")
    _write_sync_for(tgt_b_dir, "DSO-2021", "ts-tgt-b")
    _write_sync_for(src_c_dir, "DSO-2030", "ts-src-c")
    _write_sync_for(tgt_c_dir, "DSO-2031", "ts-tgt-c")

    # Timestamps: t1=100, t2=200, t3=300
    # Events created with out-of-order timestamps: t3 first, then t1, then t2
    t1, t2, t3 = 1742700100, 1742700200, 1742700300

    # t3 event (latest) -- written first in the events list
    link_file_c = _write_link_event(
        src_c_dir,
        timestamp=t3,
        uuid="ts000003-0000-0000-0000-000000000003",
        event_type="LINK",
        source_id="ts-src-c",
        target_id="ts-tgt-c",
        relation="relates_to",
    )
    # t1 event (earliest) -- written second in the events list
    link_file_a = _write_link_event(
        src_a_dir,
        timestamp=t1,
        uuid="ts000001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="ts-src-a",
        target_id="ts-tgt-a",
        relation="relates_to",
    )
    # t2 event (middle) -- written third in the events list
    link_file_b = _write_link_event(
        src_b_dir,
        timestamp=t2,
        uuid="ts000002-0000-0000-0000-000000000002",
        event_type="LINK",
        source_id="ts-src-b",
        target_id="ts-tgt-b",
        relation="relates_to",
    )

    # Input order: [t3, t1, t2] — out of order
    events = [
        {"ticket_id": "ts-src-c", "event_type": "LINK", "file_path": str(link_file_c)},
        {"ticket_id": "ts-src-a", "event_type": "LINK", "file_path": str(link_file_a)},
        {"ticket_id": "ts-src-b", "event_type": "LINK", "file_path": str(link_file_b)},
    ]

    call_order: list[str] = []

    def set_relationship_side_effect(
        from_key: str, to_key: str, link_type: str
    ) -> dict:
        call_order.append(from_key)
        return {"status": "created"}

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.set_relationship = MagicMock(side_effect=set_relationship_side_effect)

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    assert len(call_order) == 3, (
        f"Expected 3 set_relationship calls, got {len(call_order)}: {call_order}"
    )
    # Expected order: t1 (DSO-2010), t2 (DSO-2020), t3 (DSO-2030)
    assert call_order == ["DSO-2010", "DSO-2020", "DSO-2030"], (
        f"LINK events must be processed in timestamp order (t1, t2, t3); "
        f"actual call order: {call_order}. "
        f"Input was [t3={t3}, t1={t1}, t2={t2}] — timestamp ordering not yet implemented."
    )


# ---------------------------------------------------------------------------
# LINK test 17: timestamp ordering -- mixed event types: LINK/UNLINK sorted,
#               non-LINK events maintain original order
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
def test_link_unlink_sorted_while_non_link_events_maintain_original_order(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """Given a batch with mixed event types (CREATE at t2, LINK at t1, STATUS at t3),
    when process_outbound() is called,
    then LINK/UNLINK events are sorted by timestamp (t1 before t2-CREATE),
    while non-LINK events maintain their original relative order.

    This verifies that sorting is scoped to LINK/UNLINK events only and does not
    reorder unrelated event types.

    This test is RED: timestamp ordering is not yet implemented in process_outbound.
    """
    src_link_dir = tmp_path / "mix-src-link"
    tgt_link_dir = tmp_path / "mix-tgt-link"
    create_dir = tmp_path / "mix-create"
    status_dir = tmp_path / "mix-status"
    for d in [src_link_dir, tgt_link_dir, create_dir, status_dir]:
        d.mkdir()

    # LINK at t1 (earliest) — should be processed before the CREATE at t2
    t1_link = 1742800100
    t2_create = 1742800200

    _write_sync_for(src_link_dir, "DSO-3010", "mix-src-link")
    _write_sync_for(tgt_link_dir, "DSO-3020", "mix-tgt-link")

    link_file = _write_link_event(
        src_link_dir,
        timestamp=t1_link,
        uuid="mx000001-0000-0000-0000-000000000001",
        event_type="LINK",
        source_id="mix-src-link",
        target_id="mix-tgt-link",
        relation="relates_to",
    )

    # CREATE event at t2 — not a LINK/UNLINK event
    create_uuid = "mx000002-0000-0000-0000-000000000002"
    create_payload = {
        "timestamp": t2_create,
        "uuid": create_uuid,
        "event_type": "CREATE",
        "env_id": _OTHER_ENV_ID,
        "author": "Test User",
        "data": {
            "title": "Mix Create Ticket",
            "ticket_type": "task",
            "priority": 2,
        },
    }
    create_file = create_dir / f"{t2_create}-{create_uuid}-CREATE.json"
    create_file.write_text(json.dumps(create_payload))

    # Input order: [CREATE at t2, LINK at t1] — LINK comes later in list
    # but has earlier timestamp; LINK should be processed first
    events = [
        {
            "ticket_id": "mix-create",
            "event_type": "CREATE",
            "file_path": str(create_file),
        },
        {
            "ticket_id": "mix-src-link",
            "event_type": "LINK",
            "file_path": str(link_file),
        },
    ]

    call_order: list[str] = []

    def create_issue_side_effect(ticket_data: dict) -> dict:
        call_order.append("CREATE")
        return {"key": "DSO-3030"}

    def set_relationship_side_effect(
        from_key: str, to_key: str, link_type: str
    ) -> dict:
        call_order.append(f"LINK:{from_key}")
        return {"status": "created"}

    mock_client = MagicMock()
    mock_client.get_issue_link_types = MagicMock(
        return_value=[
            {"name": "Relates", "inward": "relates to", "outward": "relates to"}
        ]
    )
    mock_client.get_issue_links = MagicMock(return_value=[])
    mock_client.create_issue = MagicMock(side_effect=create_issue_side_effect)
    mock_client.set_relationship = MagicMock(side_effect=set_relationship_side_effect)

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    # Both LINK and CREATE events must be observed — if either is silently skipped,
    # the ordering assertion would be vacuously true.
    assert "LINK:DSO-3010" in call_order, (
        f"set_relationship must be called for the LINK event; call_order={call_order}"
    )
    assert "CREATE" in call_order, (
        f"create_issue must be called for the CREATE event; call_order={call_order}"
    )

    # LINK at t1 must be processed before CREATE at t2 (earlier timestamp = earlier processing).
    link_idx = call_order.index("LINK:DSO-3010")
    create_idx = call_order.index("CREATE")
    assert link_idx < create_idx, (
        f"LINK event (timestamp={t1_link}) must be processed before CREATE event "
        f"(timestamp={t2_create}) when LINK has an earlier timestamp. "
        f"Actual call order: {call_order}. "
        f"Timestamp ordering not yet implemented in process_outbound."
    )
