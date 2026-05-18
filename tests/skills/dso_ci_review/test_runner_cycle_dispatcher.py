"""RED tests for post-review cycle_dispatcher routing in runner.py.

Tests for not-yet-implemented post-review cycle_next_action wiring in main():
- main() should call cycle_next_action AFTER the review pipeline completes
- PASS action → exit 0, no arbiter dispatch, PR summary comment mentioning pass
- DISPATCH_NEXT with blocking findings → exit 1, cycle summary PR comment
- DISPATCH_NEXT with only suggestions → exit 0, PR comment still posted
- SHORT_CIRCUIT post-review (unexpected) → WARNING on stderr, exit 0

All 4 tests MUST FAIL until post-review cycle_dispatcher routing is wired into
main(). Task: 7712-629d-28e5-4eb4
"""

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Import guard — these names don't exist yet in runner.py.
# ---------------------------------------------------------------------------

try:
    from dso_ci_review.runner import _post_review_cycle_dispatch  # noqa: F401

    HAS_CYCLE_DISPATCH = True
except ImportError:
    HAS_CYCLE_DISPATCH = False


# ---------------------------------------------------------------------------
# Shared helpers / minimal env / tier result
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")


def _base_env(tmp_path):
    """Minimal env dict for runner.main() invocations."""
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"
    return {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        "WORKFLOW_PLUGIN_ARTIFACTS_DIR": str(tmp_path),
    }, diff_file, output_file


def _tier_result():
    """Minimal tier classification result."""
    return {
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
        "diff_lines": 0,
        "change_volume": 0,
        "computed_total": 1,
        "is_merge_commit": False,
    }


def _specialist_findings(severities):
    """Build a minimal specialist findings list with given severity values."""
    return [
        {
            "findings": [
                {
                    "severity": sev,
                    "description": f"test finding ({sev})",
                    "cited_lines": ["foo.py:1"],
                }
            ],
            "scores": {"correctness": 1},
            "summary": f"finding at {sev}",
        }
        for sev in severities
    ]


async def _mock_dispatch(agents):
    return _specialist_findings(["suggestion"])


# ---------------------------------------------------------------------------
# Test 1: PASS action → exit 0, no arbiter dispatch, PR comment with PASS text
# ---------------------------------------------------------------------------


def test_pass_branch_exits_zero(tmp_path):
    """
    Given: post-review cycle_next_action returns {"action": "PASS", "cycle_num": 1}
    When: runner.main() completes the review pipeline
    Then:
      - exit code is 0
      - dispatch_cycle_end_arbiter is NOT called
      - a PR comment is posted with body mentioning "zero unresolved findings" or "PASS"

    RED: fails because cycle_next_action is not called POST-review yet — there is
    no post-review routing that could produce a PASS-branch PR comment or skip
    arbiter dispatch conditionally.
    """
    if not HAS_CYCLE_DISPATCH:
        pytest.fail(
            "_post_review_cycle_dispatch not implemented — cycle_dispatcher routing "
            "missing from runner.py (post-review wiring)"
        )

    import dso_ci_review.runner as runner_mod

    env, diff_file, output_file = _base_env(tmp_path)

    # Track PR comments posted via subprocess.run
    pr_comments: list[str] = []

    def _fake_subprocess_run(args, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""
        # Capture gh pr comment / gh api comment calls
        if isinstance(args, list) and any("comment" in str(a) for a in args):
            body_idx = None
            for i, a in enumerate(args):
                if a in ("-b", "--body", "-f", "--body-file"):
                    body_idx = i + 1
                    break
            if body_idx is not None and body_idx < len(args):
                pr_comments.append(str(args[body_idx]))
        return result

    with (
        patch.dict("os.environ", env),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_tier_result(),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_mock_dispatch,
        ),
        patch("dso_ci_review.runner._init_cycle_ledger", return_value=1),
        patch(
            "dso_ci_review.runner.cycle_ledger.read_ledger",
            return_value={"cycles": []},
        ),
        # Pre-review SHORT_CIRCUIT check → CONTINUE (proceed with review)
        patch(
            "dso_ci_review.runner.cycle_next_action",
            side_effect=[
                {"action": "CONTINUE", "cycle_num": 1},  # pre-review call
                {"action": "PASS", "cycle_num": 1},  # post-review call (not wired yet)
            ],
        ),
        patch(
            "subprocess.check_output",
            return_value="deadbeef1234\n",
        ),
        patch("dso_ci_review.runner._post_pr_review", return_value=(0, 0)),
        patch("dso_ci_review.runner.cycle_ledger.append_cycle"),
        patch("dso_ci_review.runner._post_cycle_marker_comment"),
        patch(
            "dso_ci_review.arbiter.dispatch_cycle_end_arbiter"
        ) as mock_arbiter,
        patch("subprocess.run", side_effect=_fake_subprocess_run),
    ):
        exit_code = runner_mod.main()

    # Assertions
    assert exit_code == 0, (
        f"Expected exit 0 on PASS branch, got {exit_code}. "
        "Post-review cycle_next_action PASS routing is not wired."
    )

    assert mock_arbiter.call_count == 0, (
        f"dispatch_cycle_end_arbiter must NOT be called on PASS. "
        f"Called {mock_arbiter.call_count} time(s)."
    )

    pass_comment = any(
        "pass" in c.lower() or "zero unresolved" in c.lower() or "PASS" in c
        for c in pr_comments
    )
    assert pass_comment, (
        "Expected a PR comment mentioning 'PASS' or 'zero unresolved findings'. "
        f"Captured PR comments: {pr_comments!r}. "
        "Post-review PASS-branch PR summary comment not implemented."
    )


# ---------------------------------------------------------------------------
# Test 2: DISPATCH_NEXT with blocking findings → exit 1, cycle summary comment
# ---------------------------------------------------------------------------


def test_dispatch_next_with_blocking_findings_exits_one(tmp_path):
    """
    Given: post-review cycle_next_action returns {"action": "DISPATCH_NEXT", "cycle_num": 1}
           AND merged findings include one {"severity": "critical"} finding
    When: runner.main() runs the full pipeline
    Then:
      - exit code is 1 (severity gate fires on critical finding)
      - a PR comment includes "Cycle 1 complete" and "awaiting next push" or "cycle 2"

    RED: fails because post-review cycle_next_action routing is not wired — the
    cycle-summary PR comment for DISPATCH_NEXT does not exist, so the assertion
    about its contents cannot pass.
    """
    if not HAS_CYCLE_DISPATCH:
        pytest.fail(
            "_post_review_cycle_dispatch not implemented — cycle_dispatcher routing "
            "missing from runner.py (post-review wiring)"
        )

    import dso_ci_review.runner as runner_mod

    env, diff_file, output_file = _base_env(tmp_path)

    pr_comments: list[str] = []

    async def _mock_critical_dispatch(agents):
        return _specialist_findings(["critical"])

    def _fake_subprocess_run(args, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""
        if isinstance(args, list) and any("comment" in str(a) for a in args):
            body_idx = None
            for i, a in enumerate(args):
                if a in ("-b", "--body", "-f", "--body-file"):
                    body_idx = i + 1
                    break
            if body_idx is not None and body_idx < len(args):
                pr_comments.append(str(args[body_idx]))
        return result

    with (
        patch.dict("os.environ", env),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_tier_result(),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_mock_critical_dispatch,
        ),
        patch("dso_ci_review.runner._init_cycle_ledger", return_value=1),
        patch(
            "dso_ci_review.runner.cycle_ledger.read_ledger",
            return_value={"cycles": []},
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            side_effect=[
                {"action": "CONTINUE", "cycle_num": 1},  # pre-review call
                {"action": "DISPATCH_NEXT", "cycle_num": 1},  # post-review call
            ],
        ),
        patch("subprocess.check_output", return_value="deadbeef1234\n"),
        patch("dso_ci_review.runner._post_pr_review", return_value=(1, 1)),
        patch("dso_ci_review.runner.cycle_ledger.append_cycle"),
        patch("dso_ci_review.runner._post_cycle_marker_comment"),
        patch("subprocess.run", side_effect=_fake_subprocess_run),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Expected exit 1 on DISPATCH_NEXT with critical finding, got {exit_code}. "
        "Severity gate must fire on critical findings."
    )

    cycle_comment = any(
        (
            ("cycle 1" in c.lower() or "cycle 1 complete" in c.lower())
            and ("awaiting" in c.lower() or "next push" in c.lower() or "cycle 2" in c.lower())
        )
        for c in pr_comments
    )
    assert cycle_comment, (
        "Expected PR comment mentioning 'Cycle 1 complete' and "
        "'awaiting next push' or 'cycle 2'. "
        f"Captured PR comments: {pr_comments!r}. "
        "Post-review DISPATCH_NEXT cycle-summary PR comment not implemented."
    )


# ---------------------------------------------------------------------------
# Test 3: DISPATCH_NEXT with only suggestions → exit 0, PR comment still posted
# ---------------------------------------------------------------------------


def test_dispatch_next_with_only_suggestions_exits_zero(tmp_path):
    """
    Given: post-review cycle_next_action returns {"action": "DISPATCH_NEXT", "cycle_num": 1}
           AND merged findings contain only {"severity": "suggestion"} entries
    When: runner.main() runs the full pipeline
    Then:
      - exit code is 0 (severity gate does NOT fire on suggestion-only findings)
      - a PR comment is still posted (cycle summary or any comment)

    RED: fails because post-review cycle_next_action routing is not wired — without
    it the DISPATCH_NEXT cycle-summary PR comment cannot be posted, so the comment
    assertion fails regardless of the severity outcome.
    """
    if not HAS_CYCLE_DISPATCH:
        pytest.fail(
            "_post_review_cycle_dispatch not implemented — cycle_dispatcher routing "
            "missing from runner.py (post-review wiring)"
        )

    import dso_ci_review.runner as runner_mod

    env, diff_file, output_file = _base_env(tmp_path)

    pr_comments: list[str] = []

    async def _mock_suggestion_dispatch(agents):
        return _specialist_findings(["suggestion"])

    def _fake_subprocess_run(args, **kwargs):
        result = MagicMock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""
        if isinstance(args, list) and any("comment" in str(a) for a in args):
            body_idx = None
            for i, a in enumerate(args):
                if a in ("-b", "--body", "-f", "--body-file"):
                    body_idx = i + 1
                    break
            if body_idx is not None and body_idx < len(args):
                pr_comments.append(str(args[body_idx]))
        return result

    with (
        patch.dict("os.environ", env),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_tier_result(),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_mock_suggestion_dispatch,
        ),
        patch("dso_ci_review.runner._init_cycle_ledger", return_value=1),
        patch(
            "dso_ci_review.runner.cycle_ledger.read_ledger",
            return_value={"cycles": []},
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            side_effect=[
                {"action": "CONTINUE", "cycle_num": 1},  # pre-review call
                {"action": "DISPATCH_NEXT", "cycle_num": 1},  # post-review call
            ],
        ),
        patch("subprocess.check_output", return_value="deadbeef1234\n"),
        patch("dso_ci_review.runner._post_pr_review", return_value=(0, 0)),
        patch("dso_ci_review.runner.cycle_ledger.append_cycle"),
        patch("dso_ci_review.runner._post_cycle_marker_comment"),
        patch("subprocess.run", side_effect=_fake_subprocess_run),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 0, (
        f"Expected exit 0 on DISPATCH_NEXT with suggestion-only findings, got {exit_code}. "
        "Severity gate must NOT fire on suggestion-level findings."
    )

    assert len(pr_comments) > 0, (
        "Expected at least one PR comment to be posted on DISPATCH_NEXT. "
        "No PR comments captured. "
        "Post-review DISPATCH_NEXT cycle-summary PR comment not implemented."
    )


# ---------------------------------------------------------------------------
# Test 4: SHORT_CIRCUIT post-review → WARNING on stderr, exit 0
# ---------------------------------------------------------------------------


def test_defensive_post_review_short_circuit_logs_and_passes(tmp_path, capsys):
    """
    Given: post-review cycle_next_action returns {"action": "SHORT_CIRCUIT"}
           (unexpected: SHORT_CIRCUIT should only occur on a pre-review no-op re-run)
    When: runner.main() runs the full pipeline
    Then:
      - a WARNING is emitted to stderr
      - exit code is 0 (defensive PASS — treat SHORT_CIRCUIT as PASS)

    RED: fails because post-review cycle_next_action is not called at all in main()
    currently — the mock's second side_effect (SHORT_CIRCUIT) is never consumed,
    so the WARNING is never emitted and the expected defensive exit-0 branch cannot
    be exercised.
    """
    if not HAS_CYCLE_DISPATCH:
        pytest.fail(
            "_post_review_cycle_dispatch not implemented — cycle_dispatcher routing "
            "missing from runner.py (post-review wiring)"
        )

    import dso_ci_review.runner as runner_mod

    env, diff_file, output_file = _base_env(tmp_path)

    async def _mock_suggestion_dispatch(agents):
        return _specialist_findings(["suggestion"])

    with (
        patch.dict("os.environ", env),
        patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_tier_result(),
        ),
        patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        ),
        patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=_mock_suggestion_dispatch,
        ),
        patch("dso_ci_review.runner._init_cycle_ledger", return_value=1),
        patch(
            "dso_ci_review.runner.cycle_ledger.read_ledger",
            return_value={"cycles": []},
        ),
        patch(
            "dso_ci_review.runner.cycle_next_action",
            side_effect=[
                {"action": "CONTINUE", "cycle_num": 1},  # pre-review call
                {"action": "SHORT_CIRCUIT", "cycle_num": 1},  # unexpected post-review
            ],
        ),
        patch("subprocess.check_output", return_value="deadbeef1234\n"),
        patch("dso_ci_review.runner._post_pr_review", return_value=(0, 0)),
        patch("dso_ci_review.runner.cycle_ledger.append_cycle"),
        patch("dso_ci_review.runner._post_cycle_marker_comment"),
        patch("subprocess.run", return_value=MagicMock(returncode=0, stdout="", stderr="")),
    ):
        exit_code = runner_mod.main()

    assert exit_code == 0, (
        f"Expected exit 0 when post-review cycle_next_action returns SHORT_CIRCUIT "
        f"(defensive PASS), got {exit_code}. "
        "Post-review SHORT_CIRCUIT defensive branch not implemented."
    )

    captured = capsys.readouterr()
    stderr_text = captured.err
    assert "WARNING" in stderr_text or "warning" in stderr_text.lower(), (
        "Expected a WARNING on stderr when post-review cycle_next_action returns "
        "SHORT_CIRCUIT (defensive fallthrough). "
        f"Captured stderr: {stderr_text!r}. "
        "Post-review SHORT_CIRCUIT defensive WARNING log not implemented."
    )
