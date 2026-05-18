"""RED E2E integration tests for runner.main() full-cycle scenarios (task b6ca-d587-2ad6-411f).

5 end-to-end scenarios exercising runner.main() with mocked LLM dispatch.
These tests verify COMPOSITION across all integration points: cycle ledger,
PR comment posting, arbiter dispatch, and SHORT_CIRCUIT gating.

Tests are expected to fail (RED) until the corresponding GREEN implementation
is complete.
"""

from __future__ import annotations

import contextlib
import json
import pathlib
import sys
from unittest.mock import MagicMock, patch

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.runner as runner_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

_TIER_RESULT = {
    "selected_tier": "standard",
    "size_action": "none",
    "security_overlay": False,
    "performance_overlay": False,
    "test_quality_overlay": False,
    "diff_size_lines": 1,
    "blast_radius": 1,
    "critical_path": 0,
    "anti_shortcut": 0,
    "staleness": 0,
    "cross_cutting": 0,
    "diff_lines": 1,
    "change_volume": 0,
    "computed_total": 1,
    "is_merge_commit": False,
}

_EMPTY_LEDGER = {"schema_version": "1.1.0", "epic_id": "", "cycles": []}


def _make_ledger_with_cycles(cycles: list[dict]) -> dict:
    """Build a ledger dict with the given cycle entries."""
    return {"schema_version": "1.1.0", "epic_id": "", "cycles": cycles}


def _make_cycle_entry(
    cycle_num: int,
    commit_sha: str,
    findings_hash: str = "aabbccdd11223344",
    tuples: list | None = None,
) -> dict:
    return {
        "cycle_num": cycle_num,
        "commit_sha": commit_sha,
        "findings_hash": findings_hash,
        "tuples": tuples or [],
        "timestamp": "2026-01-01T00:00:00Z",
    }


def _specialist_findings(findings: list[dict] | None = None) -> list[dict]:
    """Wrap findings in the specialist response envelope."""
    return [{"findings": findings or [], "scores": {}, "summary": "test"}]


def _common_e2e_patches(
    tmp_path,
    specialist_findings_list: list[dict],
    *,
    cycle_num: int = 1,
    ledger: dict | None = None,
    max_cycles: int = 3,
    pr_number: str | None = "99",
    reviewed_sha: str = "deadbeef1234",
    extra_env: dict | None = None,
    action_result: dict | None = None,
):
    """Return an ExitStack with all standard patches for E2E runner tests.

    Patches applied:
      - _classify_tier_via_bash → _TIER_RESULT
      - async_dispatch_specialists → specialist_findings_list
      - _validate_findings_schema → schema_pass
      - dispatch_verifier → pass-through
      - cycle_next_action → action_result (default: DISPATCH_NEXT)
      - _resolve_artifacts_dir → tmp_path
      - _init_cycle_ledger → (ledger or _EMPTY_LEDGER, cycle_num)
      - _resolve_max_cycles → max_cycles
      - _resolve_pr_number → pr_number
      - _resolve_repo → "owner/repo"
      - _append_cycle → no-op spy
      - _post_cycle_marker_comment → no-op spy
      - subprocess.check_output (git rev-parse HEAD) → reviewed_sha
      - subprocess.run (gh CLI) → no-op
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    env: dict[str, str] = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        "DSO_REVIEW_CYCLE": str(cycle_num),
        "GITHUB_SHA": reviewed_sha,
        "WORKFLOW_PLUGIN_ARTIFACTS_DIR": str(tmp_path),
    }
    if pr_number is not None:
        env["PR_NUMBER"] = pr_number
    if extra_env:
        env.update(extra_env)

    _ledger = ledger if ledger is not None else _EMPTY_LEDGER
    _action_result = action_result or {
        "action": "DISPATCH_NEXT",
        "reason": "below halt threshold",
        "cycle_num": cycle_num,
    }

    async def _mock_dispatch(agents):
        return specialist_findings_list

    def _fake_subprocess_run(cmd, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stdout = json.dumps({"comments": []})
        result.stderr = ""
        return result

    stack = contextlib.ExitStack()
    stack.enter_context(patch.dict("os.environ", env, clear=False))
    stack.enter_context(
        patch("dso_ci_review.runner._classify_tier_via_bash", return_value=_TIER_RESULT)
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        )
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_mock_dispatch,
        )
    )
    stack.enter_context(
        patch(
            "dso_ci_review.verifier.dispatch_verifier",
            side_effect=lambda findings, reviewed_sha=None: findings,
        )
    )
    stack.enter_context(
        patch("dso_ci_review.runner.cycle_next_action", return_value=_action_result)
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner._resolve_artifacts_dir",
            return_value=str(tmp_path),
        )
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner._init_cycle_ledger",
            return_value=(_ledger, cycle_num),
        )
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_max_cycles", return_value=max_cycles)
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_pr_number", return_value=pr_number)
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_repo", return_value="owner/repo")
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner.subprocess.check_output",
            return_value=f"{reviewed_sha}\n",
        )
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner.subprocess.run",
            side_effect=_fake_subprocess_run,
        )
    )
    return stack


# ---------------------------------------------------------------------------
# Test 1: Cycle 1 happy path — empty ledger, no findings → exit 0, ledger updated
# ---------------------------------------------------------------------------


def test_e2e_cycle_1_happy_path(tmp_path):
    """Given: empty ledger, no PR comments, reviewer returns 0 findings.
    When: runner.main() is called on cycle 1.
    Then:
      - exit 0 (no blocking findings)
      - _append_cycle is called once (ledger has 1 entry)
      - _post_cycle_marker_comment is called once (cycle marker posted)
    """
    specialist = _specialist_findings([])  # zero findings
    action_result = {
        "action": "PASS",
        "reason": "no unresolved findings",
        "cycle_num": 1,
    }

    append_spy = MagicMock()
    marker_spy = MagicMock()

    with _common_e2e_patches(
        tmp_path,
        specialist,
        cycle_num=1,
        ledger=_EMPTY_LEDGER,
        pr_number="99",
        reviewed_sha="deadbeef0001",
        action_result=action_result,
    ):
        with (
            patch("dso_ci_review.runner._append_cycle", append_spy),
            patch("dso_ci_review.runner._post_cycle_marker_comment", marker_spy),
        ):
            exit_code = runner_mod.main()

    assert exit_code == 0, f"Expected exit 0 on happy-path cycle 1, got {exit_code}"
    assert append_spy.called, (
        "_append_cycle must be called after cycle-1 review so the ledger records cycle 1"
    )
    assert marker_spy.called, (
        "_post_cycle_marker_comment must be called to post the DSO-Review-Cycle marker"
    )


# ---------------------------------------------------------------------------
# Test 2: Cycle 2 — reconstruct ledger from PR comments when ledger file absent
# ---------------------------------------------------------------------------


def test_e2e_cycle_2_reconstructs_from_pr_comment(tmp_path):
    """Given: no ledger file on disk; PR has a DSO-Review-Cycle:cycle=1 marker comment.
    When: runner.main() is called (cycle derived from PR comment reconstruction).
    Then:
      - reconstruct_from_pr_comments is called (ledger was empty)
      - cycle number resolves to 2 (next after cycle-1 in reconstructed ledger)
      - _append_cycle is called (ledger gains entry for cycle 2)
    """
    # Simulate cycle-1 already completed: ledger has one entry (reconstructed).
    reconstructed_ledger = _make_ledger_with_cycles(
        [_make_cycle_entry(1, "sha_prev_commit")]
    )

    # specialist returns no blocking findings so we get exit 0.
    specialist = _specialist_findings([])
    action_result = {
        "action": "PASS",
        "reason": "no unresolved findings",
        "cycle_num": 2,
    }

    reconstruct_mock = MagicMock(return_value=reconstructed_ledger)
    append_spy = MagicMock()

    # _init_cycle_ledger will call reconstruct_from_pr_comments when ledger is empty.
    # We simulate this by patching _init_cycle_ledger to return the reconstructed ledger
    # AND patching cycle_ledger.reconstruct_from_pr_comments to verify it's wired.
    with _common_e2e_patches(
        tmp_path,
        specialist,
        cycle_num=2,
        ledger=reconstructed_ledger,
        pr_number="99",
        reviewed_sha="deadbeef0002",
        action_result=action_result,
    ):
        with (
            patch(
                "dso_ci_review.cycle_ledger.reconstruct_from_pr_comments",
                reconstruct_mock,
            ),
            patch("dso_ci_review.runner._append_cycle", append_spy),
        ):
            # Patch _init_cycle_ledger to mimic the real flow: empty ledger →
            # calls reconstruct_from_pr_comments → returns reconstructed ledger.
            def _fake_init_cycle_ledger(
                artifacts_dir, pr_number_arg=None, repo_arg=None
            ):
                # Simulate the real init that reads an empty file then reconstructs.
                empty = _EMPTY_LEDGER.copy()
                if pr_number_arg and repo_arg:
                    # This is the reconstruction path.
                    result = reconstruct_mock(int(pr_number_arg), repo_arg)
                    cycles = result.get("cycles", [])
                    next_num = cycles[-1]["cycle_num"] + 1 if cycles else 1
                    return result, next_num
                return empty, 1

            with patch(
                "dso_ci_review.runner._init_cycle_ledger",
                side_effect=_fake_init_cycle_ledger,
            ):
                with patch(
                    "dso_ci_review.runner._resolve_repo", return_value="owner/repo"
                ):
                    runner_mod.main()

    # reconstruct_from_pr_comments must have been called (empty ledger → PR reconstruction).
    assert reconstruct_mock.called, (
        "reconstruct_from_pr_comments must be called when the ledger file is absent "
        "and PR context (pr_number + repo) is available"
    )
    # Regardless of exit code, append_cycle must record the new cycle entry.
    assert append_spy.called, (
        "_append_cycle must be called after cycle-2 review to persist the ledger entry"
    )


# ---------------------------------------------------------------------------
# Test 3: Cycle 4 at max_cycles → DISPATCH_ARBITER fires
# ---------------------------------------------------------------------------


def test_e2e_cycle_4_triggers_arbiter_at_max_cycles(tmp_path):
    """Given: ledger has 3 entries with same findings (no convergence); max_cycles=4.
    When: reviewer returns same findings on cycle 4.
    Then:
      - dispatch_cycle_end_arbiter is called
      - _post_arbiter_comment is called (arbiter PR comment posted)
      - exit code reflects arbiter ruling (1 for BLOCK)
    """
    sha = "deadbeef0004"
    repeated_finding = {
        "severity": "important",
        "description": "persistent issue",
        "cited_lines": ["foo.py:10"],
        "category": "correctness",
        "file": "foo.py",
        "line_range": "10",
        "finding_id": "fimportant1",
    }

    ledger_with_3 = _make_ledger_with_cycles(
        [
            _make_cycle_entry(1, sha, tuples=[["foo.py", "10", "correctness"]]),
            _make_cycle_entry(2, sha, tuples=[["foo.py", "10", "correctness"]]),
            _make_cycle_entry(3, sha, tuples=[["foo.py", "10", "correctness"]]),
        ]
    )

    specialist = _specialist_findings([repeated_finding])
    action_result = {
        "action": "DISPATCH_ARBITER",
        "reason": "cycle_num=4 >= max_cycles=4",
        "cycle_num": 4,
    }

    arbiter_rulings = [
        {
            "ruling": "BLOCK",
            "rationale": "persistent important finding not resolved",
            "schema_version": "1.0.0",
            "finding_index": 0,
        }
    ]
    process_result = {
        "block": [{"ruling": arbiter_rulings[0], "finding": repeated_finding}],
        "defer_ticket_ids": [],
        "drop_defense_records": [],
        "skipped_idempotent": [],
        "skipped_invalid_index": [],
    }

    arbiter_mock = MagicMock(return_value=arbiter_rulings)
    process_mock = MagicMock(return_value=process_result)
    post_arbiter_spy = MagicMock()
    append_spy = MagicMock()

    with _common_e2e_patches(
        tmp_path,
        specialist,
        cycle_num=4,
        ledger=ledger_with_3,
        max_cycles=4,
        pr_number="99",
        reviewed_sha=sha,
        action_result=action_result,
    ):
        with (
            patch(
                "dso_ci_review.runner.dispatch_cycle_end_arbiter",
                arbiter_mock,
                create=True,
            ),
            patch("dso_ci_review.runner.process_rulings", process_mock, create=True),
            patch(
                "dso_ci_review.runner._post_arbiter_comment",
                post_arbiter_spy,
                create=True,
            ),
            patch("dso_ci_review.runner._append_cycle", append_spy),
        ):
            exit_code = runner_mod.main()

    assert arbiter_mock.called, (
        "dispatch_cycle_end_arbiter must be called when cycle_num >= max_cycles "
        "with unresolved findings (DISPATCH_ARBITER action)"
    )
    assert post_arbiter_spy.called, (
        "_post_arbiter_comment must be called to post the DSO-Arbiter-Ruling marker "
        "on the PR after arbiter dispatch"
    )
    assert exit_code == 1, (
        f"Expected exit 1 when arbiter issues BLOCK ruling, got {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test 4: STABLE_HALT → arbiter fires early (before max_cycles)
# ---------------------------------------------------------------------------


def test_e2e_stable_halt_triggers_arbiter_early(tmp_path):
    """Given: ledger has 2 entries with identical findings (Jaccard=1.0 ≥ 0.85).
    When: cycle 3 produces the same findings → STABLE_HALT → DISPATCH_ARBITER.
    Then:
      - arbiter fires on cycle 3, not cycle 4 (max_cycles=4)
      - dispatch_cycle_end_arbiter is called with cycle_num=3
      - exit 0 when arbiter issues DROP-only rulings
    """
    sha = "deadbeef0003"
    stable_finding = {
        "severity": "important",
        "description": "stable issue across cycles",
        "cited_lines": ["bar.py:20"],
        "category": "security",
        "file": "bar.py",
        "line_range": "20",
        "finding_id": "fstable1",
    }
    stable_tuples = [["bar.py", "20", "security"]]

    ledger_with_2 = _make_ledger_with_cycles(
        [
            _make_cycle_entry(1, sha, tuples=stable_tuples),
            _make_cycle_entry(2, sha, tuples=stable_tuples),
        ]
    )

    specialist = _specialist_findings([stable_finding])
    # cycle_next_action returns DISPATCH_ARBITER at cycle 3 due to STABLE_HALT
    action_result = {
        "action": "DISPATCH_ARBITER",
        "reason": "stable halt: Jaccard ≥ 0.85 at cycle 3",
        "cycle_num": 3,
    }

    # Arbiter issues DROP — no BLOCK → exit 0
    arbiter_rulings = [
        {
            "ruling": "DROP",
            "rationale": "stable finding, no regression risk",
            "schema_version": "1.0.0",
            "finding_index": 0,
        }
    ]
    process_result = {
        "block": [],
        "defer_ticket_ids": [],
        "drop_defense_records": [{"written_to": ["tracker"], "record": {}}],
        "skipped_idempotent": [],
        "skipped_invalid_index": [],
    }

    arbiter_mock = MagicMock(return_value=arbiter_rulings)
    process_mock = MagicMock(return_value=process_result)
    post_arbiter_spy = MagicMock()

    with _common_e2e_patches(
        tmp_path,
        specialist,
        cycle_num=3,
        ledger=ledger_with_2,
        max_cycles=4,  # arbiter fires at cycle 3 (stable), not 4 (max)
        pr_number="99",
        reviewed_sha=sha,
        action_result=action_result,
    ):
        with (
            patch(
                "dso_ci_review.runner.dispatch_cycle_end_arbiter",
                arbiter_mock,
                create=True,
            ),
            patch("dso_ci_review.runner.process_rulings", process_mock, create=True),
            patch(
                "dso_ci_review.runner._post_arbiter_comment",
                post_arbiter_spy,
                create=True,
            ),
        ):
            exit_code = runner_mod.main()

    assert arbiter_mock.called, (
        "dispatch_cycle_end_arbiter must be called on STABLE_HALT even when "
        "cycle_num(3) < max_cycles(4)"
    )
    # Verify arbiter was called with cycle_num=3 (early halt)
    call_args = arbiter_mock.call_args
    assert call_args is not None, "dispatch_cycle_end_arbiter was not called at all"
    all_args = list(call_args.args) + list(call_args.kwargs.values())
    int_args = [a for a in all_args if isinstance(a, int)]
    assert 3 in int_args, (
        f"dispatch_cycle_end_arbiter must be called with cycle_num=3 (early halt); "
        f"int args received: {int_args}"
    )
    assert exit_code == 0, (
        f"Expected exit 0 when arbiter issues DROP-only ruling, got {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test 5: SHORT_CIRCUIT on re-run with same SHA + arbiter-rulings.json present
# ---------------------------------------------------------------------------


def test_e2e_short_circuit_on_rerun_with_same_sha(tmp_path):
    """Given: ledger has cycle_num=2 with commit_sha=HEAD; arbiter-rulings.json present (BLOCK).
    When: runner.main() is called again on the same commit.
    Then:
      - async_dispatch_specialists is NOT called (no LLM dispatch)
      - exit 1 (BLOCK ruling from arbiter-rulings.json sidecar)
    """
    sha = "deadbeef0005"

    # Write arbiter-rulings.json sidecar with a BLOCK ruling.
    arbiter_rulings_path = tmp_path / "arbiter-rulings.json"
    arbiter_rulings_path.write_text(
        json.dumps(
            {
                "rulings": [
                    {
                        "ruling": "BLOCK",
                        "rationale": "persistent critical finding",
                        "schema_version": "1.0.0",
                        "finding_index": 0,
                    }
                ]
            }
        )
    )

    ledger_with_2 = _make_ledger_with_cycles(
        [
            _make_cycle_entry(1, sha),
            _make_cycle_entry(2, sha),
        ]
    )

    # cycle_next_action returns SHORT_CIRCUIT because same SHA + arbiter-rulings.json exists.
    action_result = {
        "action": "SHORT_CIRCUIT",
        "reason": f"arbiter already ruled on commit {sha}",
        "cycle_num": 2,
    }

    dispatch_spy = MagicMock()

    async def _spy_dispatch(agents):
        dispatch_spy(agents)
        return _specialist_findings([])

    with _common_e2e_patches(
        tmp_path,
        _specialist_findings([]),  # won't be called in SHORT_CIRCUIT
        cycle_num=2,
        ledger=ledger_with_2,
        pr_number="99",
        reviewed_sha=sha,
        action_result=action_result,
    ):
        with patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_spy_dispatch,
        ):
            exit_code = runner_mod.main()

    assert not dispatch_spy.called, (
        "async_dispatch_specialists must NOT be called on SHORT_CIRCUIT; "
        "the pre-check should detect the same SHA + arbiter-rulings.json and return early"
    )
    assert exit_code == 1, (
        f"Expected exit 1 when SHORT_CIRCUIT detects a BLOCK ruling in arbiter-rulings.json, "
        f"got {exit_code}"
    )
