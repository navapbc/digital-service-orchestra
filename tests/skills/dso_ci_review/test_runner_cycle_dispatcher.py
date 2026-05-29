"""Tests for cycle_dispatcher routing wired into runner.main() (task ba75-1ba2).

Verifies that runner.main() routes correctly on each action returned by
cycle_next_action: PASS → exit 0, SHORT_CIRCUIT → exit 0,
DISPATCH_ARBITER → exit 1, DISPATCH_NEXT → falls through to severity gate.
"""

from __future__ import annotations

import contextlib
import pathlib
import sys
from unittest.mock import patch

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.runner as runner_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Shared helpers
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


def _make_specialist_findings(severity: str | None = None) -> list[dict]:
    """Build a minimal specialist findings list."""
    if severity is None:
        return [{"findings": [], "scores": {}, "summary": "ok"}]
    return [
        {
            "findings": [
                {
                    "severity": severity,
                    "description": f"test {severity} finding",
                    "cited_lines": ["foo.py:1"],
                    "category": "correctness",
                }
            ],
            "scores": {},
            "summary": f"{severity} issue",
        }
    ]


def _common_patches(tmp_path, specialist_findings, action_result, *, extra_env=None):
    """Return an ExitStack with all patches applied for runner.main() tests.

    Patches:
      - _classify_tier_via_bash → standard tier
      - async_dispatch_specialists → specialist_findings
      - _validate_findings_schema → schema_pass
      - dispatch_verifier → pass findings through unchanged
      - cycle_next_action → action_result
      - _resolve_artifacts_dir → tmp_path
      - _init_cycle_ledger → (empty ledger, 1)
      - _resolve_max_cycles → 3
      - _resolve_pr_number → None (non-PR context)
      - _resolve_repo → None
      - _append_cycle → no-op
      - _post_cycle_marker_comment → no-op
      - subprocess.check_output (reviewed_sha) → "abc123"
    """
    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/foo.py b/foo.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    env = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
    }
    if extra_env:
        env.update(extra_env)

    empty_ledger = {"schema_version": "1.1.0", "epic_id": "", "cycles": []}

    async def mock_dispatch(agents):
        return specialist_findings

    stack = contextlib.ExitStack()
    stack.enter_context(patch.dict("os.environ", env))
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
            side_effect=mock_dispatch,
        )
    )
    stack.enter_context(
        patch(
            "dso_ci_review.verifier.dispatch_verifier",
            side_effect=lambda findings, reviewed_sha=None: findings,
        )
    )
    stack.enter_context(
        patch(
            "dso_ci_review.runner.cycle_next_action",
            return_value=action_result,
        )
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
            return_value=(empty_ledger, 1),
        )
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_max_cycles", return_value=3)
    )
    stack.enter_context(
        patch("dso_ci_review.runner._resolve_pr_number", return_value=None)
    )
    stack.enter_context(patch("dso_ci_review.runner._resolve_repo", return_value=None))
    stack.enter_context(patch("dso_ci_review.runner._append_cycle"))
    stack.enter_context(patch("dso_ci_review.runner._post_cycle_marker_comment"))
    stack.enter_context(
        patch(
            "dso_ci_review.runner.subprocess.check_output",
            return_value="abc123\n",
        )
    )
    return stack


# ---------------------------------------------------------------------------
# Test: PASS action → exit 0 (severity gate bypassed)
# ---------------------------------------------------------------------------


def test_cycle_dispatcher_pass_action_returns_exit_0(tmp_path):
    """Given: cycle_next_action returns PASS.
    When: runner.main() is called with no real findings.
    Then: exit code is 0 (severity gate not reached).
    """
    action_result = {
        "action": "PASS",
        "reason": "no unresolved findings",
        "cycle_num": 1,
    }
    # No findings → PASS makes sense; severity gate would also pass, but
    # the early return on PASS means we don't reach it.
    findings = _make_specialist_findings(severity=None)

    with _common_patches(tmp_path, findings, action_result):
        exit_code = runner_mod.main()

    assert exit_code == 0, f"Expected exit 0 on PASS action, got {exit_code}"


# ---------------------------------------------------------------------------
# Test: SHORT_CIRCUIT action → exit 0
# ---------------------------------------------------------------------------


def test_cycle_dispatcher_short_circuit_returns_exit_0(tmp_path):
    """Given: cycle_next_action returns SHORT_CIRCUIT.
    When: runner.main() is called.
    Then: exit code is 0 (arbiter already ruled; no new cycle).
    """
    action_result = {
        "action": "SHORT_CIRCUIT",
        "reason": "arbiter already ruled on commit abc123",
        "cycle_num": 2,
    }
    # Severity doesn't matter — SHORT_CIRCUIT exits early before severity gate.
    findings = _make_specialist_findings(severity="critical")

    with _common_patches(tmp_path, findings, action_result):
        exit_code = runner_mod.main()

    assert exit_code == 0, f"Expected exit 0 on SHORT_CIRCUIT action, got {exit_code}"


# ---------------------------------------------------------------------------
# Test: DISPATCH_ARBITER action → exit 1
# ---------------------------------------------------------------------------


def test_cycle_dispatcher_dispatch_arbiter_returns_exit_1(tmp_path):
    """Given: cycle_next_action returns DISPATCH_ARBITER, arbiter rules BLOCK.
    When: runner.main() is called.
    Then: exit code is 1 (arbiter blocked the cycle).

    R4 (PR-C): explicitly mock dispatch_cycle_end_arbiter + process_rulings.
    Without these mocks, the unmocked arbiter dispatch raises ValueError on
    the empty ruling string and the test was passing by accident on the
    outer except handler's legacy exit code 1 — which is now exit 4 under
    R4. The test should exercise its STATED scenario (a real BLOCK ruling).
    """
    action_result = {
        "action": "DISPATCH_ARBITER",
        "reason": "cycle_num=3 >= max_cycles=3",
        "cycle_num": 3,
    }
    findings = _make_specialist_findings(severity="important")
    arbiter_rulings = [
        {"ruling": "BLOCK", "finding_id": "test-finding-0", "reason": "blocking"}
    ]

    with _common_patches(tmp_path, findings, action_result) as stack:
        stack.enter_context(
            patch(
                "dso_ci_review.runner.dispatch_cycle_end_arbiter",
                return_value=arbiter_rulings,
            )
        )
        stack.enter_context(
            patch(
                "dso_ci_review.runner.process_rulings",
                return_value={"block": True},
            )
        )
        stack.enter_context(patch("dso_ci_review.runner._post_arbiter_comment"))
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Expected exit 1 on DISPATCH_ARBITER action with BLOCK ruling, "
        f"got {exit_code}"
    )


# ---------------------------------------------------------------------------
# Test: DISPATCH_NEXT with critical finding → exit 1 (severity gate fires)
# ---------------------------------------------------------------------------


def test_cycle_dispatcher_dispatch_next_with_critical_finding_returns_exit_1(tmp_path):
    """Given: cycle_next_action returns DISPATCH_NEXT and there is a critical finding.
    When: runner.main() is called.
    Then: exit code is 1 (severity gate blocks on the critical finding).
    """
    action_result = {
        "action": "DISPATCH_NEXT",
        "reason": "below halt threshold, below max_cycles",
        "cycle_num": 2,
    }
    findings = _make_specialist_findings(severity="critical")

    with _common_patches(tmp_path, findings, action_result):
        exit_code = runner_mod.main()

    assert exit_code == 1, (
        f"Expected exit 1 on DISPATCH_NEXT with critical finding, got {exit_code}"
    )
