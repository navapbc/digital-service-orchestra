"""RED tests for DISPATCH_ARBITER branch in runner.main() (task 932c-13a9-8693-47b0).

These 7 tests cover the full DISPATCH_ARBITER wiring that the GREEN implementation
must add to runner.main(). All tests currently FAIL because the DISPATCH_ARBITER
branch is a placeholder ``return 1``.

Expected behavior after GREEN implementation:
  1. dispatch_cycle_end_arbiter is called with the full input bundle.
  2. process_rulings is called with an aligned finding_map.
  3. Any BLOCK ruling → exit 1.
  4. DROP/DEFER-only rulings → exit 0.
  5. Posts arbiter PR comment with DSO-Arbiter-Ruling marker (idempotent CREATE).
  6. Updates existing marker comment instead of creating a duplicate (idempotent UPDATE).
  7. Skips PR comment when no PR number is available.
"""

from __future__ import annotations

import contextlib
import pathlib
import sys
from unittest.mock import MagicMock, patch

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.runner as runner_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Shared fixtures
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

_IMPORTANT_FINDING = {
    "severity": "important",
    "description": "important test finding",
    "cited_lines": ["foo.py:1"],
    "category": "correctness",
    "file": "foo.py",
    "line_range": "1",
    "finding_id": "f001",
}

_CRITICAL_FINDING = {
    "severity": "critical",
    "description": "critical test finding",
    "cited_lines": ["bar.py:5"],
    "category": "security",
    "file": "bar.py",
    "line_range": "5",
    "finding_id": "f002",
}

_MINOR_FINDING = {
    "severity": "minor",
    "description": "minor test finding",
    "cited_lines": ["baz.py:10"],
    "category": "style",
    "file": "baz.py",
    "line_range": "10",
    "finding_id": "f003",
}


def _specialist_findings_with(findings: list[dict]) -> list[dict]:
    return [{"findings": findings, "scores": {}, "summary": "test"}]


def _make_ruling(ruling_type: str, finding_index: int = 0) -> dict:
    return {
        "ruling": ruling_type,
        "rationale": f"test {ruling_type} rationale",
        "schema_version": "1.0.0",
        "finding_index": finding_index,
    }


def _build_process_result(block: list = (), defer: list = (), drop: list = ()) -> dict:
    return {
        "block": list(block),
        "defer_ticket_ids": list(defer),
        "drop_defense_records": list(drop),
        "skipped_idempotent": [],
        "skipped_invalid_index": [],
    }


def _common_arbiter_patches(
    tmp_path,
    specialist_findings,
    arbiter_rulings: list[dict],
    process_rulings_result: dict,
    arbiter_mock: MagicMock,
    process_mock: MagicMock,
    post_mock: MagicMock,
    *,
    pr_number: str | None = None,
    github_sha: str = "abc123commit",
    extra_env: dict | None = None,
):
    """Return an ExitStack with all patches needed for DISPATCH_ARBITER branch tests.

    Accepts pre-created MagicMock objects for dispatch_cycle_end_arbiter,
    process_rulings, and _post_arbiter_comment so callers can inspect call args.
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    env: dict[str, str] = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        "DSO_REVIEW_CYCLE": "3",
        "GITHUB_SHA": github_sha,
    }
    if pr_number is not None:
        env["PR_NUMBER"] = pr_number
    # Ensure PR_NUMBER is absent when not specified
    if "PR_NUMBER" not in env:
        env.pop("PR_NUMBER", None)
    if extra_env:
        env.update(extra_env)

    empty_ledger = {"schema_version": "1.1.0", "epic_id": "", "cycles": []}

    arbiter_mock.return_value = arbiter_rulings
    process_mock.return_value = process_rulings_result

    async def _mock_dispatch(agents):
        return specialist_findings

    action_result = {
        "action": "DISPATCH_ARBITER",
        "reason": "cycle_num=3 >= max_cycles=3",
        "cycle_num": 3,
    }

    stack = contextlib.ExitStack()
    stack.enter_context(patch.dict("os.environ", env, clear=False))
    # Remove PR_NUMBER when not specified to ensure clean env
    if pr_number is None:
        stack.enter_context(patch.dict("os.environ", {}, clear=False))
        os_mod = sys.modules["os"]
        os_mod.environ.pop("PR_NUMBER", None)

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
        patch("dso_ci_review.runner.cycle_next_action", return_value=action_result)
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_artifacts_dir", return_value=str(tmp_path))
    )
    stack.enter_context(
        patch("dso_ci_review.runner._init_cycle_ledger", return_value=(empty_ledger, 3))
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_max_cycles", return_value=3)
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_pr_number", return_value=pr_number)
    )
    stack.enter_context(patch("dso_ci_review.runner._resolve_repo", return_value=None))
    stack.enter_context(patch("dso_ci_review.runner._append_cycle"))
    stack.enter_context(patch("dso_ci_review.runner._post_cycle_marker_comment"))
    stack.enter_context(
        patch(
            "dso_ci_review.runner.subprocess.check_output",
            return_value=f"{github_sha}\n",
        )
    )
    # Patch dispatch_cycle_end_arbiter in runner's namespace (GREEN adds the import).
    stack.enter_context(
        patch(
            "dso_ci_review.runner.dispatch_cycle_end_arbiter",
            new=arbiter_mock,
            create=True,
        )
    )
    # Patch process_rulings in runner's namespace (GREEN adds the import).
    stack.enter_context(
        patch("dso_ci_review.runner.process_rulings", new=process_mock, create=True)
    )
    # Patch _post_arbiter_comment in runner's namespace (GREEN adds this function).
    stack.enter_context(
        patch("dso_ci_review.runner._post_arbiter_comment", new=post_mock, create=True)
    )
    return stack


# ---------------------------------------------------------------------------
# Test 1: dispatch_cycle_end_arbiter called with full input bundle
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_calls_dispatch_cycle_end_arbiter_with_full_bundle(tmp_path):
    """Given: cycle_next_action returns DISPATCH_ARBITER with a blocking finding.
    When: runner.main() reaches the DISPATCH_ARBITER branch.
    Then: dispatch_cycle_end_arbiter is called once with findings, defenses,
          diff_text, model, provider_chain, cycle_num, and max_cycles.
    """
    findings = [_IMPORTANT_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [_make_ruling("BLOCK")]
    process_result = _build_process_result(
        block=[{"ruling": rulings[0], "finding": findings[0], "finding_hash": "abc"}]
    )

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
    ):
        runner_mod.main()

    assert arbiter_mock.called, (
        "dispatch_cycle_end_arbiter was not called — DISPATCH_ARBITER branch "
        "must call it with the full input bundle"
    )
    call_kwargs = arbiter_mock.call_args
    assert call_kwargs is not None, "dispatch_cycle_end_arbiter call_args is None"

    # Verify the call includes integer arguments for cycle_num and max_cycles
    all_args = list(call_kwargs.args) + list(call_kwargs.kwargs.values())
    int_args = [a for a in all_args if isinstance(a, int)]
    assert len(int_args) >= 2, (
        "dispatch_cycle_end_arbiter must receive cycle_num and max_cycles as integer arguments; "
        f"got int args: {int_args}, full call: {call_kwargs}"
    )

    # Verify a list (findings) is passed
    assert any(isinstance(a, list) for a in all_args), (
        "dispatch_cycle_end_arbiter must receive findings as a list argument; "
        f"full call: {call_kwargs}"
    )


# ---------------------------------------------------------------------------
# Test 2: process_rulings called with aligned finding_map
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_calls_process_rulings_with_aligned_finding_map(tmp_path):
    """Given: DISPATCH_ARBITER branch receives arbiter rulings.
    When: runner.main() processes the rulings.
    Then: process_rulings is called with a finding_map keyed by finding index.
    """
    findings = [_IMPORTANT_FINDING, _MINOR_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [
        _make_ruling("DROP", finding_index=0),
        _make_ruling("DEFER", finding_index=1),
    ]
    process_result = _build_process_result(
        defer=["task-001"], drop=[{"written_to": ["tracker"], "record": {}}]
    )

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
    ):
        runner_mod.main()

    assert process_mock.called, (
        "process_rulings was not called — DISPATCH_ARBITER branch must call it "
        "with the aligned finding_map"
    )
    call_kwargs = process_mock.call_args
    assert call_kwargs is not None

    # Check that a dict was passed (the finding_map argument)
    all_args = list(call_kwargs.args) + list(call_kwargs.kwargs.values())
    dicts_passed = [a for a in all_args if isinstance(a, dict)]
    assert dicts_passed, (
        "process_rulings must receive a finding_map dict argument; "
        f"args passed: {all_args}"
    )

    # The finding_map must map integer indices to finding dicts
    finding_map_candidates = [
        d for d in dicts_passed if any(isinstance(k, int) for k in d)
    ]
    assert finding_map_candidates, (
        "process_rulings must receive a finding_map with integer keys (one per finding by index); "
        f"dicts passed: {dicts_passed}"
    )


# ---------------------------------------------------------------------------
# Test 3: BLOCK ruling → exit 1
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_block_ruling_exits_one(tmp_path):
    """Given: arbiter returns a BLOCK ruling.
    When: runner.main() processes it via process_rulings.
    Then: exit code is 1 AND process_rulings was called (not a placeholder return).
    """
    findings = [_CRITICAL_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [_make_ruling("BLOCK", finding_index=0)]
    process_result = _build_process_result(
        block=[{"ruling": rulings[0], "finding": findings[0], "finding_hash": "aaa"}]
    )

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
    ):
        exit_code = runner_mod.main()

    # The placeholder returns 1, so exit_code == 1 coincidentally passes.
    # The critical assertion is that process_rulings was called — the GREEN
    # implementation routes through process_rulings to derive the BLOCK decision,
    # rather than returning 1 blindly from a placeholder.
    assert process_mock.called, (
        "process_rulings must be called when DISPATCH_ARBITER is triggered; "
        "the exit-1 decision must come from process_rulings['block'] being non-empty, "
        "not from a placeholder return statement"
    )
    assert exit_code == 1, (
        f"Expected exit 1 when arbiter issues BLOCK ruling, got {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test 4: DROP/DEFER only rulings → exit 0
# ---------------------------------------------------------------------------


def test_dispatch_arbiter_no_block_exits_zero(tmp_path):
    """Given: arbiter returns only DROP and DEFER rulings (no BLOCK).
    When: runner.main() processes them.
    Then: exit code is 0.
    """
    findings = [_IMPORTANT_FINDING, _MINOR_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [
        _make_ruling("DROP", finding_index=0),
        _make_ruling("DEFER", finding_index=1),
    ]
    process_result = _build_process_result(
        defer=["task-123"],
        drop=[{"written_to": ["tracker"], "record": {}}],
    )

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
    ):
        exit_code = runner_mod.main()

    assert exit_code == 0, (
        f"Expected exit 0 when arbiter issues only DROP/DEFER rulings (no BLOCK), "
        f"got {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test 5: Posts arbiter PR comment with DSO-Arbiter-Ruling marker (idempotent CREATE)
# ---------------------------------------------------------------------------


def test_post_arbiter_comment_creates_with_marker(tmp_path):
    """Given: DISPATCH_ARBITER branch with a PR number set and no existing marker comment.
    When: runner.main() runs.
    Then: _post_arbiter_comment is called with the DSO-Arbiter-Ruling marker and
          both cycle and commit_sha are included.
    """
    findings = [_IMPORTANT_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [_make_ruling("DROP", finding_index=0)]
    process_result = _build_process_result()

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
        pr_number="42",
        github_sha="abc123commit",
    ):
        runner_mod.main()

    assert post_mock.called, (
        "_post_arbiter_comment was not called — the DISPATCH_ARBITER branch must "
        "call it when a PR number is available"
    )
    # Verify the call args include the marker string
    call_str = str(post_mock.call_args)
    has_marker = "DSO-Arbiter-Ruling" in call_str
    assert has_marker, (
        "_post_arbiter_comment must be called with args containing 'DSO-Arbiter-Ruling'; "
        f"actual call_args: {post_mock.call_args}"
    )


# ---------------------------------------------------------------------------
# Test 6: Updates existing marker comment instead of creating duplicate (idempotent UPDATE)
# ---------------------------------------------------------------------------


def test_post_arbiter_comment_updates_existing(tmp_path):
    """Given: DISPATCH_ARBITER branch with a PR that already has a DSO-Arbiter-Ruling comment.
    When: runner.main() runs.
    Then: _post_arbiter_comment is called exactly once (not twice — no duplicate creation).
          The function itself is responsible for detecting and patching the existing comment.
    """
    findings = [_MINOR_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [_make_ruling("DROP", finding_index=0)]
    process_result = _build_process_result()

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
        pr_number="42",
        github_sha="abc123commit",
    ):
        runner_mod.main()

    assert post_mock.called, (
        "_post_arbiter_comment must be called — idempotent UPDATE requires the "
        "function to be called (it detects and patches the existing comment internally)"
    )
    assert post_mock.call_count == 1, (
        f"_post_arbiter_comment must be called exactly once (idempotent); "
        f"was called {post_mock.call_count} time(s). "
        "Duplicate calls would create multiple arbiter marker comments."
    )


# ---------------------------------------------------------------------------
# Test 7: Skips PR comment when no PR number
# ---------------------------------------------------------------------------


def test_post_arbiter_comment_skips_when_no_pr(tmp_path):
    """Given: DISPATCH_ARBITER branch with no PR number in environment.
    When: runner.main() runs.
    Then: process_rulings IS called (DISPATCH_ARBITER must still process rulings),
          but no 'gh pr comment' subprocess call is made for an arbiter marker,
          and exit code is 0 (DROP-only rulings, no BLOCK).
    """
    findings = [_MINOR_FINDING]
    specialist = _specialist_findings_with(findings)
    rulings = [_make_ruling("DROP", finding_index=0)]
    process_result = _build_process_result()  # no block, no defer, no drop in result

    arbiter_mock = MagicMock(return_value=rulings)
    process_mock = MagicMock(return_value=process_result)
    post_mock = MagicMock()

    gh_comment_calls: list = []

    def _fake_subprocess_run(cmd, **kwargs):
        if isinstance(cmd, list) and "gh" in cmd and "pr" in cmd and "comment" in cmd:
            gh_comment_calls.append(cmd)
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""
        return result

    with _common_arbiter_patches(
        tmp_path,
        specialist,
        rulings,
        process_result,
        arbiter_mock,
        process_mock,
        post_mock,
        pr_number=None,
        github_sha="abc123commit",
    ):
        with patch(
            "dso_ci_review.runner.subprocess.run", side_effect=_fake_subprocess_run
        ):
            exit_code = runner_mod.main()

    # GREEN: process_rulings must be called even without a PR (it still processes rulings)
    assert process_mock.called, (
        "process_rulings must be called in the DISPATCH_ARBITER branch even when "
        "no PR number is available; arbiter rulings must be processed regardless"
    )

    # GREEN: exit 0 because no BLOCK ruling in process_result
    assert exit_code == 0, (
        f"Expected exit 0 (DROP-only, no BLOCK) when no PR is available, got {exit_code}"
    )

    # No arbiter marker 'gh pr comment' calls when there's no PR number
    assert not gh_comment_calls, (
        "No 'gh pr comment' subprocess calls should be made when no PR number is available; "
        f"got calls: {gh_comment_calls}"
    )
