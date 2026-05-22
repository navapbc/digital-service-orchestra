"""Outbound handlers must write dedup'd BRIDGE_ALERTs on missing SYNC marker.

Pre-fix: COMMENT / EDIT / LINK-source / FILE_IMPACT / SNAPSHOT silently
returned when the ticket had no SYNC.json, dropping the event without an
operator-visible trail. STATUS already had retroactive-CREATE + alert; these
tests pin the same surface for the other handlers.

The alert must carry a stable dedup_key so cron ticks against the same
unfixed ticket do not flood the tracker.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "bridge-outbound.py"

_BRIDGE_ENV_ID = "bbbbbbbb-0000-4000-8000-000000000002"
_OTHER_ENV_ID = "aaaaaaaa-0000-4000-8000-000000000001"
_UUID = "11112222-3333-4444-5555-666677778888"


@pytest.fixture(scope="module")
def bridge() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bridge_outbound", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _write_event(
    ticket_dir: Path,
    event_type: str,
    data: dict,
    *,
    ts: int = 1742605400,
    uuid: str = _UUID,
    env_id: str = _OTHER_ENV_ID,
) -> Path:
    filename = f"{ts}-{uuid}-{event_type}.json"
    payload = {
        "event_type": event_type,
        "timestamp": ts,
        "uuid": uuid,
        "env_id": env_id,
        "author": "Test User",
        "data": data,
    }
    path = ticket_dir / filename
    path.write_text(json.dumps(payload))
    return path


def _alert_dedup_keys(ticket_dir: Path) -> list[str]:
    keys = []
    for alert in sorted(ticket_dir.glob("*-BRIDGE_ALERT.json")):
        try:
            payload = json.loads(alert.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        k = (payload.get("data") or {}).get("dedup_key")
        if k:
            keys.append(k)
    return keys


@pytest.mark.unit
@pytest.mark.scripts
def test_edit_event_no_sync_marker_writes_dedup_alert(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """EDIT on a ticket with no SYNC marker must write a dedup'd BRIDGE_ALERT."""
    ticket_dir = tmp_path / "edit-no-sync"
    ticket_dir.mkdir()

    edit_path = _write_event(
        ticket_dir,
        "EDIT",
        {"fields": {"title": "Updated title"}},
    )

    events = [
        {
            "ticket_id": "edit-no-sync",
            "event_type": "EDIT",
            "file_path": str(edit_path),
        }
    ]

    mock_client = MagicMock()

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.update_issue.assert_not_called()

    keys_first = _alert_dedup_keys(ticket_dir)
    assert keys_first, (
        "EDIT on a no-SYNC ticket must write a BRIDGE_ALERT — silent return "
        "hides dropped edits from operators."
    )

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )
    keys_second = _alert_dedup_keys(ticket_dir)
    assert len(keys_second) == len(keys_first), (
        "EDIT no-SYNC alert must dedup across runs; "
        f"saw {len(keys_first)} after first run, {len(keys_second)} after second."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_file_impact_event_no_sync_marker_writes_dedup_alert(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """FILE_IMPACT on a ticket with no SYNC marker must write a dedup'd BRIDGE_ALERT."""
    ticket_dir = tmp_path / "fi-no-sync"
    ticket_dir.mkdir()

    fi_path = _write_event(
        ticket_dir,
        "FILE_IMPACT",
        {"file_impact": [{"path": "src/foo.py", "impact": "modified"}]},
    )

    events = [
        {
            "ticket_id": "fi-no-sync",
            "event_type": "FILE_IMPACT",
            "file_path": str(fi_path),
        }
    ]

    mock_client = MagicMock()

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.set_issue_property.assert_not_called()
    mock_client.add_comment.assert_not_called()

    keys_first = _alert_dedup_keys(ticket_dir)
    assert keys_first, "FILE_IMPACT on a no-SYNC ticket must write a BRIDGE_ALERT."

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )
    keys_second = _alert_dedup_keys(ticket_dir)
    assert len(keys_second) == len(keys_first), (
        "FILE_IMPACT no-SYNC alert must dedup across runs."
    )


@pytest.mark.unit
@pytest.mark.scripts
def test_snapshot_event_no_sync_marker_writes_dedup_alert(
    tmp_path: Path, bridge: ModuleType
) -> None:
    """SNAPSHOT on a ticket with no SYNC marker must write a dedup'd BRIDGE_ALERT.

    Pre-fix: SNAPSHOT silently no-ops because compiled_state alone cannot drive
    a Jira CREATE — but operators have no signal that the compacted ticket's
    state change was dropped.
    """
    ticket_dir = tmp_path / "snap-no-sync"
    ticket_dir.mkdir()

    snap_path = _write_event(
        ticket_dir,
        "SNAPSHOT",
        {"compiled_state": {"status": "in_progress", "title": "Compacted"}},
    )

    events = [
        {
            "ticket_id": "snap-no-sync",
            "event_type": "SNAPSHOT",
            "file_path": str(snap_path),
        }
    ]

    mock_client = MagicMock()

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )

    mock_client.update_issue.assert_not_called()

    keys_first = _alert_dedup_keys(ticket_dir)
    assert keys_first, (
        "SNAPSHOT on a no-SYNC ticket must write a BRIDGE_ALERT — silent "
        "no-op hides compacted-ticket state divergence."
    )

    bridge.process_outbound(
        events,
        acli_client=mock_client,
        tickets_root=tmp_path,
        bridge_env_id=_BRIDGE_ENV_ID,
    )
    keys_second = _alert_dedup_keys(ticket_dir)
    assert len(keys_second) == len(keys_first), (
        "SNAPSHOT no-SYNC alert must dedup across runs."
    )
