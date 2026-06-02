"""runner.py _init_cycle_ledger must scope cycle_number by (pr_number, sha).

Task: 8eb2-a13b-d58f-4a94  (S2.T3)

The function under test is _init_cycle_ledger (runner.py:143-170).

Current behaviour (broken):
  cycles[-1]['cycle_num'] + 1
  — takes the LAST entry in the cycles list regardless of pr_number, so two PRs
    sharing the same commit_sha collide and return the wrong cycle_number.

Expected behaviour after the fix:
  Filter cycles to entries where entry['pr_number'] == int(pr_number) (treating
  absent / sentinel-0 pr_number entries as belonging to all PRs for backward-compat,
  per the v1.2.0 sentinel convention established by S2.T1).
  Then derive cycle_number from the filtered list.

All tests in this file MUST FAIL on current runner.py because the filtering is
This is the contract under test.
"""

from __future__ import annotations

import json
import pathlib
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.runner as runner_mod  # noqa: E402

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _write_ledger(path: pathlib.Path, cycles: list[dict]) -> None:
    """Write a v1.2.0-shaped ledger with given cycles to *path*."""
    ledger = {
        "schema_version": "1.2.0",
        "epic_id": "",
        "cycles": cycles,
    }
    path.write_text(json.dumps(ledger))


def _make_entry(
    cycle_num: int,
    commit_sha: str,
    pr_number: int,
    findings_hash: str = "h0",
) -> dict:
    """Return a v1.2.0 cycle entry dict with a pr_number field."""
    return {
        "cycle_num": cycle_num,
        "commit_sha": commit_sha,
        "pr_number": pr_number,
        "findings": [],
        "findings_hash": findings_hash,
        "halt_reason": None,
    }


# ---------------------------------------------------------------------------
# Test 1: Two PRs share the same commit_sha; each has one cycle.
#         Requesting cycle_number for PR 42 must return 2 (its next cycle),
#         NOT 3 (which bare-sha derivation would return from the last entry).
# ---------------------------------------------------------------------------


def test_cycle_number_for_pr42_ignores_pr99_entry(tmp_path: pathlib.Path) -> None:
    """
    Given: ledger with
        [{pr_number: 42, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 1}]
        (PR 42 on cycle 1; PR 99 also on cycle 1 — same SHA, different PRs)
    When: _init_cycle_ledger is called with pr_number="42"
    Then: returned cycle_number == 2 (PR 42's next cycle)
          NOT 2 (which happens to be the same here) — but to expose the collision
          we use a fixture where PR 99 is ahead of PR 42.

    Without the fix: _init_cycle_ledger uses cycles[-1]['cycle_num'] + 1 = 2 — this accidentally
         passes for this fixture because both PRs are on cycle 1. See test 2 for
         the fixture that reliably catches the bug.
    """
    # NOTE: This test is a control case (single entry per PR, same cycle level).
    # The decisive case is test 2 below. Keep this as a sanity check.
    cycles = [
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=42),
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=99),
    ]
    _write_ledger(tmp_path / "cycle-ledger.json", cycles)

    _, cycle_number = runner_mod._init_cycle_ledger(
        artifacts_dir=str(tmp_path),
        pr_number="42",
        repo=None,
    )

    assert cycle_number == 2, (
        f"Expected cycle_number=2 for PR 42 (1 prior cycle), got {cycle_number!r}. "
        "The ledger has 1 cycle for PR 42 — next cycle must be 2."
    )


# ---------------------------------------------------------------------------
# Test 2: PR 99 is on cycle 2; PR 42 is still on cycle 1.
#         Requesting cycle_number for PR 42 must return 2, NOT 3.
#
# Decisive test: #   bare-sha derivation: cycles[-1]['cycle_num'] + 1 = 2 + 1 = 3   ← WRONG
#   pr-scoped derivation: max(cycles where pr=42)['cycle_num'] + 1 = 1 + 1 = 2 ← CORRECT
# ---------------------------------------------------------------------------


def test_cycle_number_for_pr42_with_pr99_ahead(tmp_path: pathlib.Path) -> None:
    """
    Given: ledger with
        [{pr_number: 42, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 2}]
        (PR 99 is on cycle 2; PR 42 is still on cycle 1)
    When: _init_cycle_ledger is called with pr_number="42"
    Then: returned cycle_number == 2  (PR 42's next cycle)
          NOT 3 (cycles[-1]['cycle_num'] + 1 = 2 + 1 = 3 — the bare-sha bug)

    Without the fix: current runner.py line 166 returns cycles[-1]['cycle_num'] + 1 = 3, not 2.
    """
    cycles = [
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=42),
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=99),
        _make_entry(cycle_num=2, commit_sha="abc123", pr_number=99),
    ]
    _write_ledger(tmp_path / "cycle-ledger.json", cycles)

    _, cycle_number = runner_mod._init_cycle_ledger(
        artifacts_dir=str(tmp_path),
        pr_number="42",
        repo=None,
    )

    assert cycle_number == 2, (
        f"Expected cycle_number=2 for PR 42 (only 1 prior cycle), got {cycle_number!r}. "
        "Bare-sha derivation returns 3 (cycles[-1]['cycle_num']+1 from PR 99's cycle 2). "
        "The fix must scope filtering to pr_number=42 before deriving cycle_number."
    )


# ---------------------------------------------------------------------------
# Test 3: Symmetric control — requesting cycle_number for PR 99 must return 3.
#         This confirms PR-scoped derivation works in both directions.
# ---------------------------------------------------------------------------


def test_cycle_number_for_pr99_returns_three(tmp_path: pathlib.Path) -> None:
    """
    Given: same ledger as test 2
        [{pr_number: 42, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 2}]
    When: _init_cycle_ledger is called with pr_number="99"
    Then: returned cycle_number == 3 (PR 99's next cycle — it has 2 prior cycles)

    Without the fix: current bare-sha derivation accidentally returns cycles[-1]['cycle_num'] + 1 = 3
         which is numerically correct for PR 99 — but ONLY by accident (it reads the
         last entry which happens to belong to PR 99). After the fix, this test must
         still pass because the scoped result is also 3 for PR 99. If the fix
         accidentally breaks this, it's a regression. Keeping this as a control gate.

    NOTE: This test may PASS on current (broken) runner.py — that's expected.
    It is included to ensure the fix does not break the "correct" side of the collision.
    """
    cycles = [
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=42),
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=99),
        _make_entry(cycle_num=2, commit_sha="abc123", pr_number=99),
    ]
    _write_ledger(tmp_path / "cycle-ledger.json", cycles)

    _, cycle_number = runner_mod._init_cycle_ledger(
        artifacts_dir=str(tmp_path),
        pr_number="99",
        repo=None,
    )

    assert cycle_number == 3, (
        f"Expected cycle_number=3 for PR 99 (2 prior cycles), got {cycle_number!r}."
    )


# ---------------------------------------------------------------------------
# Test 4: New PR (pr_number=7) with no prior cycles for that PR on sha=abc123.
#         Must return cycle_number=1, not whatever the last cross-PR entry says.
# ---------------------------------------------------------------------------


def test_cycle_number_for_new_pr_returns_one(tmp_path: pathlib.Path) -> None:
    """
    Given: ledger with
        [{pr_number: 42, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 1},
         {pr_number: 99, commit_sha: "abc123", cycle_num: 2}]
    When: _init_cycle_ledger is called with pr_number="7" (no prior cycles for PR 7)
    Then: returned cycle_number == 1

    Without the fix: bare-sha derivation returns cycles[-1]['cycle_num'] + 1 = 3, not 1.
    """
    cycles = [
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=42),
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=99),
        _make_entry(cycle_num=2, commit_sha="abc123", pr_number=99),
    ]
    _write_ledger(tmp_path / "cycle-ledger.json", cycles)

    _, cycle_number = runner_mod._init_cycle_ledger(
        artifacts_dir=str(tmp_path),
        pr_number="7",
        repo=None,
    )

    assert cycle_number == 1, (
        f"Expected cycle_number=1 for new PR 7 (no prior cycles), got {cycle_number!r}. "
        "Bare-sha derivation returns 3 (takes last entry regardless of pr_number). "
        "The fix must return 1 when no cycles exist for the given pr_number."
    )


# ---------------------------------------------------------------------------
# Test 5: Backward-compat — sentinel pr_number=0 entries (migrated from v1.1.0)
#         must NOT be filtered out when no pr-specific entries exist yet.
#         A sentinel-0 entry counts for all PRs.
# ---------------------------------------------------------------------------


def test_sentinel_pr_number_zero_counts_for_all_prs(tmp_path: pathlib.Path) -> None:
    """
    Given: ledger with one sentinel entry
        [{pr_number: 0, commit_sha: "abc123", cycle_num: 1}]
        (pr_number=0 is the v1.1.0->v1.2.0 migration sentinel per S2.T1)
    When: _init_cycle_ledger is called with pr_number="42"
    Then: returned cycle_number == 2
          (sentinel-0 is treated as belonging to all PRs for backward-compat)

    Without the fix: after the fix adds pr-scoped filtering, it must NOT exclude sentinel-0
    entries. If the fix naively filters to pr_number==42 only, this test would
    return 1 (wrong). The test asserts the correct sentinel-0 inclusion.

    Note: with no pr_number
    filtering at all, cycles[-1]['cycle_num'] + 1 = 2, which is accidentally
    correct. But the failing case is test 2 and test 4 above.
    This test guards against a naive "only exact pr_number match" fix that
    would break backward-compat by ignoring sentinel-0 entries.
    """
    cycles = [
        _make_entry(cycle_num=1, commit_sha="abc123", pr_number=0),
    ]
    _write_ledger(tmp_path / "cycle-ledger.json", cycles)

    _, cycle_number = runner_mod._init_cycle_ledger(
        artifacts_dir=str(tmp_path),
        pr_number="42",
        repo=None,
    )

    assert cycle_number == 2, (
        f"Expected cycle_number=2 for PR 42 when sentinel pr_number=0 entry exists, "
        f"got {cycle_number!r}. "
        "Sentinel-0 entries must be treated as matching all PRs (v1.1.0 compat)."
    )


# ---------------------------------------------------------------------------
# Test 6: reconstruction_gaps=True + partial stale matching + env floor
#
# This tests the fix for bug c6bf-19df-ac83-43fb:
#   - cycle-1 CI run was cancelled (no ledger entry written to PR comments)
#   - reconstruct_from_pr_comments returned reconstruction_gaps=True and
#     a stale partial entry [{cycle_num:1}] (from an unrelated prior run)
#   - DSO_REVIEW_CYCLE=3 (set by CI to indicate the actual re-review cycle)
#   - Without fix: matching[-1]['cycle_num'] + 1 = 2 (wrong — ignores env floor)
#   - With fix: env floor applied → cycle_number = 3
# ---------------------------------------------------------------------------


def test_init_cycle_ledger_reconstruction_gaps_applies_env_floor(
    tmp_path: pathlib.Path, monkeypatch: "pytest.MonkeyPatch"
) -> None:
    """
    Given: empty on-disk ledger (no cycles in file),
           reconstruct_from_pr_comments returns reconstruction_gaps=True
           with partial stale matching=[{cycle_num:1}] for PR 284,
           DSO_REVIEW_CYCLE=3 in environment
    When: _init_cycle_ledger is called with pr_number="284", repo="org/repo"
    Then: cycle_number == 3 (env floor applied, not 2 from matching[-1]+1)

    RED before fix: current code returns 2 (wrong)
        — matching=[{cycle_num:1}] → matching[-1]['cycle_num']+1 = 2
        — reconstruction_gaps=True is never consulted as an env-floor trigger
    GREEN after fix: reconstruction_gaps=True AND env_cycle(3) > derived(2)
        → apply env as floor → cycle_number = 3
    """
    import json
    import unittest.mock as mock

    from dso_ci_review import cycle_ledger as cycle_ledger_mod

    # Empty on-disk ledger — triggers reconstruction path
    ledger_path = tmp_path / "cycle-ledger.json"
    ledger_path.write_text(
        json.dumps({"schema_version": "1.2.0", "cycles": [], "epic_id": ""})
    )

    # reconstruct_from_pr_comments returns partial stale data with reconstruction_gaps=True
    partial_ledger = {
        "schema_version": "1.2.0",
        "cycles": [
            {
                "cycle_num": 1,
                "pr_number": 284,
                "commit_sha": "abc123stale",
                "findings": [],
                "findings_hash": "h0",
                "halt_reason": None,
            }
        ],
        "reconstruction_gaps": True,
    }

    monkeypatch.setenv("DSO_REVIEW_CYCLE", "3")

    import dso_ci_review.runner as runner_mod  # noqa: PLC0415 — local import to pick up patched env

    with mock.patch.object(
        cycle_ledger_mod, "reconstruct_from_pr_comments", return_value=partial_ledger
    ):
        ledger, cycle_number = runner_mod._init_cycle_ledger(
            artifacts_dir=str(tmp_path),
            pr_number="284",
            repo="org/repo",
        )

    assert cycle_number == 3, (
        f"Expected cycle_number=3 (env floor on reconstruction_gaps=True), "
        f"got {cycle_number!r}. "
        "When reconstruction_gaps=True AND DSO_REVIEW_CYCLE(3) > derived(2), "
        "the env floor must be applied so the correct cycle context is used."
    )
