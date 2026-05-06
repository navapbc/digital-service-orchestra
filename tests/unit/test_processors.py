"""Unit tests for fork detection and tie-break logic in process_status().

These tests assert the NEW fork-detection behavior where a status conflict
(current_status in event != state["status"]) triggers a lexical tie-break
on parent_status_uuid instead of accumulating into state["conflicts"].

All tests in this file cover the fork-detection behavior implemented in epic
3e74-56da (T13). They are expected to PASS against the current implementation.
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
    """Fork resolution log line includes ticket=, winner=, dropped=[], and loser_env_id=[] fields.

    Setup:
        - state["status"] = "in_progress", state["parent_status_uuid"] = "zzzz-9999"
        - Incoming event uuid="evt-winner-uuid", parent_status_uuid="aaaa-0000" (lower -> wins)
        - State chain uuid="zzzz-9999" (higher -> loses)

    Expected stderr to contain all four spec-required fields:
        ticket=<id>
        winner=<winner_uuid>
        dropped=[<loser_uuid>]
        loser_env_id=[<env_id>]
    """
    state = {
        "status": "in_progress",
        "parent_status_uuid": "zzzz-9999",
        "ticket_id": "test-1234",
        "last_status_env_id": "env-losing-chain",
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

    assert "winner=" in stderr, f"Expected 'winner=' in fork log; got stderr={stderr!r}"
    assert "dropped=[" in stderr, (
        f"Expected 'dropped=[' in fork log; got stderr={stderr!r}"
    )
    assert "ticket=" in stderr, f"Expected 'ticket=' in fork log; got stderr={stderr!r}"
    assert "loser_env_id=[env-losing-chain]" in stderr, (
        f"Expected 'loser_env_id=[env-losing-chain]' in fork log; got stderr={stderr!r}"
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


@pytest.mark.unit
def test_concurrent_siblings_deterministic_by_event_uuid(tmp_path: Path) -> None:
    """Concurrent siblings (same parent_status_uuid) must resolve deterministically.

    RED marker — test_concurrent_siblings_deterministic_by_event_uuid
    Must FAIL before process_status uses event['uuid'] for tie-break.

    Scenario: two STATUS events both pointing to the same parent (e.g. both
    spawned immediately after an 'open' → 'in_progress' event with uuid
    "parent-0000"). Their parent pointers are IDENTICAL, so the legacy tie-break
    comparing parent_status_uuid values is non-deterministic (incoming always
    wins when both UUIDs are equal).

    Setup:
        - Event A: uuid="aaaa-0000" (lower), target="closed"
        - Event B: uuid="zzzz-9999" (higher), target="blocked"
        - Both have parent_status_uuid="parent-0000" (same parent)

    Expected deterministic outcome in BOTH replay orders:
        - Event A wins (lower event UUID) → state["status"] == "closed"

    Current (buggy) behavior:
        - Replay order 1 (B first, then A): incoming A wins → "closed" ✓
        - Replay order 2 (A first, then B): incoming B wins → "blocked" ✗
        - Non-deterministic: same events, different result depending on order
    """
    shared_parent = "parent-0000"

    def _make_initial_state(first_event_uuid: str, first_target: str) -> dict:
        state: dict = {"status": "open", "parent_status_uuid": shared_parent}
        event, data = _make_status_event(
            current_status="open",
            target_status=first_target,
            parent_status_uuid=shared_parent,
            uuid=first_event_uuid,
        )
        process_status(state, event, data, str(tmp_path / "first.json"))
        return state

    # Replay order 1: B first (zzzz), then A (aaaa) arrives as fork
    state1 = _make_initial_state("zzzz-9999", "blocked")
    event_a, data_a = _make_status_event(
        current_status="open",  # fork: doesn't match "blocked"
        target_status="closed",
        parent_status_uuid=shared_parent,
        uuid="aaaa-0000",
    )
    process_status(state1, event_a, data_a, str(tmp_path / "a.json"))

    # Replay order 2: A first (aaaa), then B (zzzz) arrives as fork
    state2 = _make_initial_state("aaaa-0000", "closed")
    event_b, data_b = _make_status_event(
        current_status="open",  # fork: doesn't match "closed"
        target_status="blocked",
        parent_status_uuid=shared_parent,
        uuid="zzzz-9999",
    )
    process_status(state2, event_b, data_b, str(tmp_path / "b.json"))

    # Both orders must produce the same winner: event A (uuid="aaaa-0000" < "zzzz-9999")
    assert state1["status"] == "closed", (
        f"Replay order 1 (B first): expected 'closed' (A wins by lower event UUID); "
        f"got {state1['status']!r}"
    )
    assert state2["status"] == "closed", (
        f"Replay order 2 (A first): expected 'closed' (A wins by lower event UUID); "
        f"got {state2['status']!r}"
    )
