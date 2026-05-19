"""RED tests for dso_ci_review.local_workflow — cycle ledger init semantics.

Tests cover _init_local_ledger(artifacts_dir, branch_name, commit_sha):
  - reads an existing ledger and returns the correct next cycle_num
  - starts fresh (cycle_num=1) when no ledger file exists
  - resets to cycle_num=1 when HEAD commit SHA differs from last cycle's SHA
  - continues from cycle_num+1 when SHA matches last cycle (idempotent re-run)
  - never calls reconstruct_from_pr_comments in local mode
  - handles concurrent init without losing cycle entries (real multiprocessing)

All 6 tests fail until local_workflow.py is created (Story 7034-071c).

The import is deferred to inside each test function so that pytest can collect
the test IDs even before the module exists. Each test fails with
ModuleNotFoundError at import-time (RED phase).

RED marker: tests/skills/dso_ci_review/test_local_workflow_ledger.py [test_local_workflow_reads_existing_ledger]
"""

from __future__ import annotations

import json
import multiprocessing
import pathlib
import sys

import pytest  # noqa: F401

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SHA_A = "a" * 40
_SHA_B = "b" * 40


def _make_ledger(cycles: list[dict]) -> dict:
    """Construct a minimal v1.1.0 ledger dict."""
    return {"schema_version": "1.1.0", "epic_id": "", "cycles": cycles}


def _make_cycle(cycle_num: int, commit_sha: str) -> dict:
    return {
        "cycle_num": cycle_num,
        "timestamp_utc": "2026-05-18T00:00:00Z",
        "commit_sha": commit_sha,
        "findings": [],
        "findings_hash": f"h{cycle_num}",
        "halt_reason": None,
    }


# ---------------------------------------------------------------------------
# Test 1 — reads existing ledger, returns next cycle_num
# ---------------------------------------------------------------------------


def test_local_workflow_reads_existing_ledger(tmp_path):
    """Given: a ledger file with 2 completed cycles, same commit SHA.
    When: _init_local_ledger is called with that SHA.
    Then: returns cycle_num=3 (continues from last cycle + 1).
    """
    from unittest.mock import patch

    # Deferred import — fails with ModuleNotFoundError in RED phase
    from dso_ci_review.local_workflow import _init_local_ledger  # noqa: PLC0415

    ledger_path = tmp_path / "cycle-ledger.json"
    ledger = _make_ledger(
        [
            _make_cycle(1, _SHA_A),
            _make_cycle(2, _SHA_A),
        ]
    )
    ledger_path.write_text(json.dumps(ledger))

    with (
        patch("dso_ci_review.cycle_ledger.read_ledger") as mock_read,
        patch(
            "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments"
        ) as mock_reconstruct,
    ):
        mock_read.return_value = ledger
        mock_reconstruct.side_effect = AssertionError(
            "reconstruct_from_pr_comments must never be called in local mode"
        )

        result = _init_local_ledger(
            artifacts_dir=str(tmp_path),
            branch_name="feature/x",
            commit_sha=_SHA_A,
        )

    assert result["cycle_num"] == 3, (
        f"Expected cycle_num=3 (continuing from 2 existing cycles on same SHA), "
        f"got {result.get('cycle_num')!r}"
    )
    assert result["ledger"] == ledger, (
        f"Expected returned ledger to match existing ledger; got {result.get('ledger')!r}"
    )


# ---------------------------------------------------------------------------
# Test 2 — starts fresh when no ledger file exists
# ---------------------------------------------------------------------------


def test_local_workflow_starts_fresh_when_no_ledger(tmp_path):
    """Given: no ledger file at artifacts_dir/cycle-ledger.json.
    When: _init_local_ledger is called.
    Then: returns cycle_num=1 and an empty cycles list (fresh start).
    """
    from unittest.mock import patch

    from dso_ci_review.local_workflow import _init_local_ledger  # noqa: PLC0415

    empty_ledger = _make_ledger([])

    with (
        patch("dso_ci_review.cycle_ledger.read_ledger") as mock_read,
        patch(
            "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments"
        ) as mock_reconstruct,
    ):
        mock_read.return_value = empty_ledger
        mock_reconstruct.side_effect = AssertionError(
            "reconstruct_from_pr_comments must never be called in local mode"
        )

        result = _init_local_ledger(
            artifacts_dir=str(tmp_path),
            branch_name="feature/y",
            commit_sha=_SHA_A,
        )

    assert result["cycle_num"] == 1, (
        f"Expected cycle_num=1 on empty ledger (fresh start), "
        f"got {result.get('cycle_num')!r}"
    )
    assert result["ledger"]["cycles"] == [], (
        f"Expected empty cycles list on fresh start, "
        f"got {result['ledger'].get('cycles')!r}"
    )


# ---------------------------------------------------------------------------
# Test 3 — resets to cycle_num=1 when commit SHA differs from last cycle
# ---------------------------------------------------------------------------


def test_local_workflow_resets_on_sha_change(tmp_path):
    """Given: a ledger with 2 cycles under SHA_A; called with SHA_B.
    When: _init_local_ledger detects SHA mismatch.
    Then: returns cycle_num=1 (counter reset for new commit).
    """
    from unittest.mock import patch

    from dso_ci_review.local_workflow import _init_local_ledger  # noqa: PLC0415

    ledger = _make_ledger(
        [
            _make_cycle(1, _SHA_A),
            _make_cycle(2, _SHA_A),
        ]
    )

    with (
        patch("dso_ci_review.cycle_ledger.read_ledger") as mock_read,
        patch(
            "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments"
        ) as mock_reconstruct,
    ):
        mock_read.return_value = ledger
        mock_reconstruct.side_effect = AssertionError(
            "reconstruct_from_pr_comments must never be called in local mode"
        )

        result = _init_local_ledger(
            artifacts_dir=str(tmp_path),
            branch_name="feature/z",
            commit_sha=_SHA_B,  # Different SHA — must reset
        )

    assert result["cycle_num"] == 1, (
        f"Expected cycle_num=1 after SHA change (counter reset), "
        f"got {result.get('cycle_num')!r}"
    )


# ---------------------------------------------------------------------------
# Test 4 — continues from cycle_num+1 when SHA matches last cycle
# ---------------------------------------------------------------------------


def test_local_workflow_continues_on_same_sha(tmp_path):
    """Given: a ledger with cycle 1 under SHA_A; called again with SHA_A.
    When: _init_local_ledger detects same SHA.
    Then: returns cycle_num=2 (idempotent re-run protection continues from last+1).
    """
    from unittest.mock import patch

    from dso_ci_review.local_workflow import _init_local_ledger  # noqa: PLC0415

    ledger = _make_ledger([_make_cycle(1, _SHA_A)])

    with (
        patch("dso_ci_review.cycle_ledger.read_ledger") as mock_read,
        patch(
            "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments"
        ) as mock_reconstruct,
    ):
        mock_read.return_value = ledger
        mock_reconstruct.side_effect = AssertionError(
            "reconstruct_from_pr_comments must never be called in local mode"
        )

        result = _init_local_ledger(
            artifacts_dir=str(tmp_path),
            branch_name="feature/w",
            commit_sha=_SHA_A,
        )

    assert result["cycle_num"] == 2, (
        f"Expected cycle_num=2 (continuing from 1 existing cycle on same SHA), "
        f"got {result.get('cycle_num')!r}"
    )


# ---------------------------------------------------------------------------
# Test 5 — reconstruct_from_pr_comments NEVER called in local mode
# ---------------------------------------------------------------------------


def test_local_workflow_no_pr_reconstruction_path(tmp_path):
    """Given: any ledger state.
    When: _init_local_ledger runs in local mode.
    Then: reconstruct_from_pr_comments is NEVER called — it is a CI-only path.
    """
    from unittest.mock import patch

    from dso_ci_review.local_workflow import _init_local_ledger  # noqa: PLC0415

    empty_ledger = _make_ledger([])

    with (
        patch("dso_ci_review.cycle_ledger.read_ledger") as mock_read,
        patch(
            "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments"
        ) as mock_reconstruct,
    ):
        mock_read.return_value = empty_ledger
        mock_reconstruct.return_value = empty_ledger  # Would succeed if called

        _init_local_ledger(
            artifacts_dir=str(tmp_path),
            branch_name="main",
            commit_sha=_SHA_A,
        )

    assert mock_reconstruct.call_count == 0, (
        f"reconstruct_from_pr_comments was called {mock_reconstruct.call_count} time(s) "
        "in local mode — this path is only valid in CI (PR-number context). "
        "Local mode must read ledger from filesystem only."
    )


# ---------------------------------------------------------------------------
# Test 6 — concurrent init via real multiprocessing (no mocking of lock layer)
# ---------------------------------------------------------------------------


def _worker_init_ledger(artifacts_dir: str, branch_name: str, commit_sha: str) -> None:
    """Worker function for multiprocessing.Process — calls _init_local_ledger
    and appends its result to the ledger file to create a visible side effect.

    This function must be a top-level definition for pickle serialization.
    """
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    scripts_dir = str(repo_root / "plugins" / "dso" / "scripts")
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)

    from dso_ci_review.local_workflow import _init_local_ledger  # noqa: PLC0415
    from dso_ci_review.cycle_ledger import append_cycle  # noqa: PLC0415

    result = _init_local_ledger(
        artifacts_dir=artifacts_dir,
        branch_name=branch_name,
        commit_sha=commit_sha,
    )
    # Write a cycle entry using the assigned cycle_num so we can assert both landed
    append_cycle(
        path=str(pathlib.Path(artifacts_dir) / "cycle-ledger.json"),
        cycle_num=result["cycle_num"],
        findings_tuples=[],
        commit_sha=commit_sha,
        findings_hash=f"worker-{result['cycle_num']}",
    )


def test_concurrent_init_no_lost_cycle_entries(tmp_path):
    """Given: a fresh ledger file (empty cycles).
    When: 2 processes concurrently call _init_local_ledger + append_cycle.
    Then: the final ledger has exactly 2 cycle entries — no writes are lost.

    Uses REAL multiprocessing.Process and a REAL tmp_path ledger file.
    The fcntl lock in _init_local_ledger must serialize the read-modify-write
    so neither worker's entry is overwritten by the other.
    """
    # Create an empty ledger file so both workers find it pre-existing
    ledger_path = tmp_path / "cycle-ledger.json"
    empty_ledger = _make_ledger([])
    ledger_path.write_text(json.dumps(empty_ledger))

    p1 = multiprocessing.Process(
        target=_worker_init_ledger,
        args=(str(tmp_path), "feature/concurrent", _SHA_A),
    )
    p2 = multiprocessing.Process(
        target=_worker_init_ledger,
        args=(str(tmp_path), "feature/concurrent", _SHA_A),
    )

    p1.start()
    p2.start()
    p1.join(timeout=30)
    p2.join(timeout=30)

    assert p1.exitcode == 0, (
        f"Worker 1 exited with code {p1.exitcode} — _init_local_ledger raised"
    )
    assert p2.exitcode == 0, (
        f"Worker 2 exited with code {p2.exitcode} — _init_local_ledger raised"
    )

    final_ledger = json.loads(ledger_path.read_text())
    cycle_nums = sorted(c["cycle_num"] for c in final_ledger.get("cycles", []))

    assert len(cycle_nums) == 2, (
        f"Expected exactly 2 cycle entries after concurrent init+append, "
        f"got {len(cycle_nums)}: {cycle_nums}. "
        f"One worker's write was lost — fcntl lock not protecting the "
        f"read-modify-write in _init_local_ledger."
    )

    # Each worker must have gotten a distinct cycle_num (1 and 2)
    assert cycle_nums == [1, 2], (
        f"Expected cycle_nums [1, 2] (serialized via lock), got {cycle_nums}. "
        f"Full cycles: {final_ledger.get('cycles')!r}"
    )
