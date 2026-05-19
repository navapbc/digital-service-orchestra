"""RED tests for dso_ci_review.local_workflow multi-cycle review loop.

These tests exercise the FUTURE multi-cycle loop in local_workflow.main().
They FAIL because local_workflow.py does not yet implement the loop —
the module itself does not yet exist, so imports are deferred to runtime.

Story: 7034-071c-82b1-4cae  Task: 9740-0303-c873-4691
"""
from __future__ import annotations

import json
import pathlib
import sys
from unittest.mock import patch

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


# ---------------------------------------------------------------------------
# Import helper — deferred so pytest can collect tests even before the module
# exists. Each test that needs main() calls _get_main() which will raise
# ImportError / ModuleNotFoundError at runtime (causing FAIL, not ERROR).
# ---------------------------------------------------------------------------


def _get_main():
    """Import and return local_workflow.main at test runtime."""
    from dso_ci_review.local_workflow import main  # noqa: PLC0415

    return main


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_finding(severity: str = "minor") -> dict:
    return {"severity": severity, "file": "x.py", "line_range": "1", "category": "c"}


# ---------------------------------------------------------------------------
# Test 1 — three cycles then PASS
# ---------------------------------------------------------------------------


def test_loop_dispatches_three_cycles_then_pass(tmp_path):
    """main() runs three review cycles then returns 0 when PASS is received."""
    main = _get_main()

    artifacts_dir = str(tmp_path)
    commit_sha = "abc123"

    # next_action sequence:
    #   call 0 (pre-loop, findings=[]) → DISPATCH_NEXT
    #   call 1 (post-cycle-1)          → DISPATCH_NEXT
    #   call 2 (post-cycle-2)          → DISPATCH_NEXT
    #   call 3 (post-cycle-3)          → PASS
    next_action_responses = [
        {"action": "DISPATCH_NEXT", "reason": "first cycle", "cycle_num": 1},
        {"action": "DISPATCH_NEXT", "reason": "second cycle", "cycle_num": 2},
        {"action": "DISPATCH_NEXT", "reason": "third cycle", "cycle_num": 3},
        {"action": "PASS", "reason": "stable", "cycle_num": 3},
    ]

    with (
        patch(
            "dso_ci_review.cycle_dispatcher.next_action",
            side_effect=next_action_responses,
        ),
        patch(
            "dso_ci_review.local_workflow._dispatch_local_reviewer",
            return_value=[],
        ) as mock_reviewer,
        patch("dso_ci_review.cycle_ledger.append_cycle") as mock_append,
    ):
        result = main(
            artifacts_dir=artifacts_dir,
            commit_sha=commit_sha,
            diff_text="some diff",
            max_cycles=4,
        )

    assert mock_reviewer.call_count == 3, (
        f"Expected reviewer dispatched 3 times, got {mock_reviewer.call_count}"
    )
    assert mock_append.call_count == 3, (
        f"Expected append_cycle called 3 times, got {mock_append.call_count}"
    )
    assert result == 0, f"Expected return code 0 (PASS), got {result}"


# ---------------------------------------------------------------------------
# Test 2 — one cycle, no findings, then PASS
# ---------------------------------------------------------------------------


def test_loop_returns_pass_after_one_cycle_with_no_findings(tmp_path):
    """main() exits 0 after a single cycle when PASS is returned immediately."""
    main = _get_main()

    artifacts_dir = str(tmp_path)

    next_action_responses = [
        {"action": "DISPATCH_NEXT", "reason": "start", "cycle_num": 1},
        {"action": "PASS", "reason": "no findings", "cycle_num": 1},
    ]

    with (
        patch(
            "dso_ci_review.cycle_dispatcher.next_action",
            side_effect=next_action_responses,
        ),
        patch(
            "dso_ci_review.local_workflow._dispatch_local_reviewer",
            return_value=[],
        ) as mock_reviewer,
        patch("dso_ci_review.cycle_ledger.append_cycle") as mock_append,
    ):
        result = main(
            artifacts_dir=artifacts_dir,
            commit_sha="deadbeef",
            diff_text="diff",
            max_cycles=3,
        )

    assert mock_reviewer.call_count == 1, (
        f"Expected reviewer dispatched 1 time, got {mock_reviewer.call_count}"
    )
    assert mock_append.call_count == 1, (
        f"Expected append_cycle called 1 time, got {mock_append.call_count}"
    )
    assert result == 0, f"Expected return code 0, got {result}"


# ---------------------------------------------------------------------------
# Test 3 — four cycles then DISPATCH_ARBITER
# ---------------------------------------------------------------------------


def test_loop_breaks_on_dispatch_arbiter_at_max_cycles(tmp_path):
    """main() invokes arbiter hook and returns non-zero when DISPATCH_ARBITER."""
    main = _get_main()

    artifacts_dir = str(tmp_path)

    # pre-loop + cycles 1-3 → DISPATCH_NEXT; cycle 4 → DISPATCH_ARBITER
    next_action_responses = [
        {"action": "DISPATCH_NEXT", "reason": "start", "cycle_num": 1},
        {"action": "DISPATCH_NEXT", "reason": "c1", "cycle_num": 1},
        {"action": "DISPATCH_NEXT", "reason": "c2", "cycle_num": 2},
        {"action": "DISPATCH_NEXT", "reason": "c3", "cycle_num": 3},
        {"action": "DISPATCH_ARBITER", "reason": "halt boundary", "cycle_num": 4},
    ]

    with (
        patch(
            "dso_ci_review.cycle_dispatcher.next_action",
            side_effect=next_action_responses,
        ),
        patch(
            "dso_ci_review.local_workflow._dispatch_local_reviewer",
            return_value=[],
        ) as mock_reviewer,
        patch("dso_ci_review.cycle_ledger.append_cycle"),
        patch(
            "dso_ci_review.local_workflow._invoke_arbiter_hook",
            return_value=1,
        ) as mock_arbiter,
    ):
        result = main(
            artifacts_dir=artifacts_dir,
            commit_sha="cafebabe",
            diff_text="diff",
            max_cycles=4,
        )

    assert mock_reviewer.call_count == 4, (
        f"Expected reviewer dispatched 4 times, got {mock_reviewer.call_count}"
    )
    assert mock_arbiter.call_count == 1, (
        f"Expected arbiter invoked 1 time, got {mock_arbiter.call_count}"
    )
    assert result != 0, (
        f"Expected non-zero return when arbiter dispatched, got {result}"
    )


# ---------------------------------------------------------------------------
# Test 4 — SHORT_CIRCUIT pre-loop with prior arbiter BLOCK ruling
# ---------------------------------------------------------------------------


def test_loop_short_circuits_pre_loop_with_prior_arbiter(tmp_path):
    """main() exits 1 immediately when pre-loop next_action returns SHORT_CIRCUIT and rulings block."""
    main = _get_main()

    artifacts_dir = str(tmp_path)

    # Write a fake arbiter-rulings.json with a BLOCK ruling
    rulings_path = tmp_path / "arbiter-rulings.json"
    rulings_path.write_text(json.dumps([{"ruling": "BLOCK", "reason": "critical finding"}]))

    pre_loop_response = {
        "action": "SHORT_CIRCUIT",
        "reason": "same sha, arbiter rulings exist",
        "cycle_num": 2,
    }

    with (
        patch(
            "dso_ci_review.cycle_dispatcher.next_action",
            return_value=pre_loop_response,
        ),
        patch(
            "dso_ci_review.local_workflow._dispatch_local_reviewer",
        ) as mock_reviewer,
        patch("dso_ci_review.cycle_ledger.append_cycle"),
    ):
        result = main(
            artifacts_dir=artifacts_dir,
            commit_sha="deadbeef",
            diff_text="diff",
            max_cycles=3,
        )

    assert mock_reviewer.call_count == 0, (
        f"Expected reviewer NOT dispatched on SHORT_CIRCUIT, got {mock_reviewer.call_count} calls"
    )
    assert result == 1, (
        f"Expected return code 1 (BLOCK ruling present), got {result}"
    )


# ---------------------------------------------------------------------------
# Test 5 — ledger append called with correct cycle numbers per iteration
# ---------------------------------------------------------------------------


def test_loop_atomic_ledger_append_per_cycle(tmp_path):
    """append_cycle is called with cycle_num=1 for first iteration, cycle_num=2 for second."""
    main = _get_main()

    artifacts_dir = str(tmp_path)
    findings_list = [_make_finding()]

    next_action_responses = [
        {"action": "DISPATCH_NEXT", "reason": "start", "cycle_num": 1},
        {"action": "DISPATCH_NEXT", "reason": "c1 done", "cycle_num": 1},
        {"action": "PASS", "reason": "stable", "cycle_num": 2},
    ]

    append_calls: list[tuple] = []

    def _capture_append(ledger_path, cycle_num, findings_tuples, commit_sha, findings_hash):
        append_calls.append((ledger_path, cycle_num, findings_tuples, commit_sha, findings_hash))

    with (
        patch(
            "dso_ci_review.cycle_dispatcher.next_action",
            side_effect=next_action_responses,
        ),
        patch(
            "dso_ci_review.local_workflow._dispatch_local_reviewer",
            return_value=findings_list,
        ),
        patch(
            "dso_ci_review.cycle_ledger.append_cycle",
            side_effect=_capture_append,
        ),
    ):
        result = main(
            artifacts_dir=artifacts_dir,
            commit_sha="sha999",
            diff_text="diff text",
            max_cycles=3,
        )

    assert len(append_calls) == 2, (
        f"Expected 2 append_cycle calls, got {len(append_calls)}"
    )
    first_cycle_num = append_calls[0][1]
    second_cycle_num = append_calls[1][1]
    assert first_cycle_num == 1, (
        f"Expected first append_cycle call with cycle_num=1, got {first_cycle_num}"
    )
    assert second_cycle_num == 2, (
        f"Expected second append_cycle call with cycle_num=2, got {second_cycle_num}"
    )
    assert result == 0
