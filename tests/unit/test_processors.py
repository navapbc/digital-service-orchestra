"""Unit tests for fork detection and tie-break logic in process_status().

These tests assert the NEW fork-detection behavior where a status conflict
(current_status in event != state["status"]) triggers a lexical tie-break
on parent_status_uuid instead of accumulating into state["conflicts"].

All tests in this file are RED — they MUST FAIL against the current
process_status() implementation and PASS only after T13 is applied.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Path setup — conftest.py adds plugins/dso/scripts but we re-insert here
# for explicit documentation of the import path.
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

from ticket_reducer._processors import process_status  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_status_event(
    *,
    current_status: str,
    target_status: str,
    parent_status_uuid: str,
    uuid: str = "evt-uuid-001",
) -> tuple[dict, dict]:
    """Build a minimal (event, data) pair for a STATUS event."""
    event = {
        "event_type": "STATUS",
        "uuid": uuid,
        "timestamp": 1_000_000,
        "author": "Test",
    }
    data = {
        "current_status": current_status,
        "status": target_status,
        "parent_status_uuid": parent_status_uuid,
    }
    return event, data


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_fork_tiebreak_lower_wins(tmp_path: Path) -> None:
    """Lower parent_status_uuid wins the tie-break when a fork is detected.

    Setup:
        - state["status"] = "in_progress"  (reflects chain B with uuid "zzzz-9999")
        - state["parent_status_uuid"] = "zzzz-9999"
        - Incoming event A: current_status="open" (doesn't match "in_progress" -> fork),
          parent_status_uuid="aaaa-0000" (lower than "zzzz-9999"), target="closed"

    Lower UUID "aaaa-0000" wins over "zzzz-9999".
    Winner's target_status "closed" should overwrite state["status"].

    Expected:
        - state["status"] == "closed"  (winner's target applied, NOT the stale "in_progress")
    """
    state = {
        "status": "in_progress",
        "parent_status_uuid": "zzzz-9999",
    }
    event, data = _make_status_event(
        current_status="open",  # doesn't match state["status"] -> fork
        target_status="closed",  # winner's target (distinct from current state)
        parent_status_uuid="aaaa-0000",  # lower -> wins
        uuid="evt-a",
    )
    filepath = str(tmp_path / "evt-a-STATUS.json")
    process_status(state, event, data, filepath)

    assert state["status"] == "closed", (
        f"Expected state['status']='closed' (lower UUID wins, target applied); "
        f"got {state['status']!r}"
    )


@pytest.mark.unit
def test_fork_no_conflicts_key(tmp_path: Path) -> None:
    """After fork detection and tie-break, state must NOT have a 'conflicts' key.

    The old behavior accumulated conflicts into state["conflicts"]. The new
    behavior resolves via tie-break and never writes that key.

    Setup:
        - state["status"] = "in_progress", state["parent_status_uuid"] = "mmmm-5555"
        - Incoming event has current_status="open" (mismatch -> fork)

    Expected:
        - "conflicts" not in state
    """
    state = {
        "status": "in_progress",
        "parent_status_uuid": "mmmm-5555",
    }
    event, data = _make_status_event(
        current_status="open",
        target_status="closed",
        parent_status_uuid="aaaa-0000",
        uuid="evt-fork-nc",
    )
    filepath = str(tmp_path / "evt-fork-nc-STATUS.json")
    process_status(state, event, data, filepath)

    assert "conflicts" not in state, (
        f"Expected no 'conflicts' key after fork resolution; got state keys: {list(state.keys())!r}"
    )


@pytest.mark.unit
def test_fork_emits_resolved_log(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """Fork detection emits PARENT_CHAIN_FORK_RESOLVED to stderr.

    Setup:
        - state["status"] = "in_progress", state["parent_status_uuid"] = "zzzz-9999"
        - Incoming event: current_status="open" (mismatch -> fork)

    Expected:
        - stderr contains "PARENT_CHAIN_FORK_RESOLVED"
    """
    state = {
        "status": "in_progress",
        "parent_status_uuid": "zzzz-9999",
    }
    event, data = _make_status_event(
        current_status="open",
        target_status="closed",
        parent_status_uuid="aaaa-0000",
        uuid="evt-fork-log",
    )
    filepath = str(tmp_path / "evt-fork-log-STATUS.json")
    process_status(state, event, data, filepath)

    captured = capsys.readouterr()
    assert "PARENT_CHAIN_FORK_RESOLVED" in captured.err, (
        f"Expected 'PARENT_CHAIN_FORK_RESOLVED' in stderr; got stderr={captured.err!r}"
    )


@pytest.mark.unit
def test_fork_log_has_winner_dropped_format(
    tmp_path: Path, capsys: pytest.CaptureFixture
) -> None:
    """Fork resolution log line includes source=, dropped=, and target_status= fields.

    Setup:
        - state["status"] = "in_progress", state["parent_status_uuid"] = "zzzz-9999"
        - Incoming event uuid="evt-winner-uuid", parent_status_uuid="aaaa-0000" (lower -> wins)
        - State chain uuid="zzzz-9999" (higher -> loses)

    Expected stderr to contain all three fields:
        source=<winner_uuid>
        dropped=<loser_uuid>
        target_status=<target>
    """
    state = {
        "status": "in_progress",
        "parent_status_uuid": "zzzz-9999",
    }
    event, data = _make_status_event(
        current_status="open",
        target_status="closed",
        parent_status_uuid="aaaa-0000",  # lower -> wins
        uuid="evt-winner-uuid",
    )
    filepath = str(tmp_path / "evt-winner-uuid-STATUS.json")
    process_status(state, event, data, filepath)

    captured = capsys.readouterr()
    stderr = captured.err

    assert "source=" in stderr, f"Expected 'source=' in fork log; got stderr={stderr!r}"
    assert "dropped=" in stderr, (
        f"Expected 'dropped=' in fork log; got stderr={stderr!r}"
    )
    assert "target_status=" in stderr, (
        f"Expected 'target_status=' in fork log; got stderr={stderr!r}"
    )


@pytest.mark.unit
def test_normal_update_no_fork_log(
    tmp_path: Path, capsys: pytest.CaptureFixture
) -> None:
    """Non-conflicting STATUS event updates state with no PARENT_CHAIN_FORK_RESOLVED log.

    Setup:
        - state["status"] = "open"  (matches current_status in event)
        - Incoming event: current_status="open", target="in_progress"

    Expected:
        - state["status"] == "in_progress"
        - "PARENT_CHAIN_FORK_RESOLVED" NOT in stderr
    """
    state = {
        "status": "open",
        "parent_status_uuid": "bbbb-1111",
    }
    event, data = _make_status_event(
        current_status="open",  # matches state["status"] -> no fork
        target_status="in_progress",
        parent_status_uuid="cccc-2222",
        uuid="evt-normal",
    )
    filepath = str(tmp_path / "evt-normal-STATUS.json")
    process_status(state, event, data, filepath)

    assert state["status"] == "in_progress", (
        f"Expected state['status']='in_progress' after normal update; got {state['status']!r}"
    )

    captured = capsys.readouterr()
    assert "PARENT_CHAIN_FORK_RESOLVED" not in captured.err, (
        f"Expected no fork log for non-conflicting event; got stderr={captured.err!r}"
    )


@pytest.mark.unit
def test_backwards_compat_existing_conflicts_key(tmp_path: Path) -> None:
    """Legacy SNAPSHOT state with conflicts key: no crash, conflicts key absent after non-conflicting event.

    Some legacy SNAPSHOTs may have compiled_state containing a 'conflicts' key.
    After replaying a non-conflicting STATUS event on such a state, the result
    must not crash AND should not retain the 'conflicts' key in the active state.

    Setup:
        - state["status"] = "open", state["conflicts"] = [{"some": "data"}]  (legacy)
        - Incoming event: current_status="open" (matches) -> no fork

    Expected:
        - No exception raised
        - state["status"] == "in_progress"
        - "conflicts" not in state  (new behavior clears legacy conflicts key)
    """
    state = {
        "status": "open",
        "parent_status_uuid": "dddd-3333",
        "conflicts": [{"some": "data"}],  # legacy SNAPSHOT artifact
    }
    event, data = _make_status_event(
        current_status="open",  # matches state["status"] -> no fork
        target_status="in_progress",
        parent_status_uuid="eeee-4444",
        uuid="evt-compat",
    )
    filepath = str(tmp_path / "evt-compat-STATUS.json")

    # Must not raise
    process_status(state, event, data, filepath)

    assert state["status"] == "in_progress", (
        f"Expected state['status']='in_progress'; got {state['status']!r}"
    )
    assert "conflicts" not in state, (
        f"Expected 'conflicts' key absent after processing; got state keys: {list(state.keys())!r}"
    )
