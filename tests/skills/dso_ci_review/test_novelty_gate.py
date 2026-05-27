"""
RED tests for _apply_novelty_gate in runner.py.
All tests must fail before T3 (GREEN) implements _apply_novelty_gate.
"""

from __future__ import annotations

import pathlib
from unittest.mock import patch
from dso_ci_review.runner import _apply_novelty_gate


def _make_finding(
    *,
    relation=None,
    cited_lines=None,
    severity="critical",
    escape_rationale=None,
    **kwargs,
):
    """Helper to build a minimal finding dict."""
    finding = {"severity": severity, "cited_lines": cited_lines or []}
    if relation is not None:
        finding["relation"] = relation
    if escape_rationale is not None:
        finding["escape_rationale"] = escape_rationale
    finding.update(kwargs)
    return finding


# ---------------------------------------------------------------------------
# Test 1: unjustified NEW_INTRODUCED finding is downgraded
# ---------------------------------------------------------------------------
def test_novelty_gate_downgrades_unjustified_new_introduced():
    finding = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["other.py:10"],
        severity="critical",
    )
    findings_in = [finding]
    defenses = []
    diff_text = "some diff"

    result_findings, _stats = _apply_novelty_gate(
        findings=findings_in,
        defenses=defenses,
        diff_text=diff_text,
        cycle_number=2,
    )

    assert result_findings[0]["severity"] == "suggestion"
    assert result_findings[0].get("_novelty_gate_reason") == "unjustified-novelty-claim"


# ---------------------------------------------------------------------------
# Test 2: finding with valid escape_rationale is NOT downgraded
# ---------------------------------------------------------------------------
def test_novelty_gate_passes_with_valid_escape_rationale():
    finding = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["other.py:10"],
        severity="critical",
        escape_rationale="token_word is only present in new context (line 10)",
    )
    defenses = []
    diff_text = "token_word some diff content line 10"

    with patch("dso_ci_review.runner.validate_escape_rationale", return_value=True):
        result_findings, _stats = _apply_novelty_gate(
            findings=[finding],
            defenses=defenses,
            diff_text=diff_text,
            cycle_number=2,
        )

    assert result_findings[0]["severity"] == "critical"
    assert "_novelty_gate_reason" not in result_findings[0]


# ---------------------------------------------------------------------------
# Test 3: proximity-anchored finding is NOT downgraded
# ---------------------------------------------------------------------------
def test_novelty_gate_skips_when_proximity_anchored():
    finding = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["runner.py:42"],
        severity="important",
    )
    defense = {"cited_lines": ["runner.py:43"]}
    defenses = [defense]
    diff_text = "some diff"

    result_findings, _stats = _apply_novelty_gate(
        findings=[finding],
        defenses=defenses,
        diff_text=diff_text,
        cycle_number=2,
    )

    assert result_findings[0]["severity"] == "important"
    assert "_novelty_gate_reason" not in result_findings[0]


# ---------------------------------------------------------------------------
# Test 4: cycle_number=1 — gate is skipped entirely
# ---------------------------------------------------------------------------
def test_novelty_gate_skips_cycle1():
    finding = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["other.py:10"],
        severity="critical",
    )
    defenses = []
    diff_text = "some diff"

    result_findings, _stats = _apply_novelty_gate(
        findings=[finding],
        defenses=defenses,
        diff_text=diff_text,
        cycle_number=1,
    )

    assert result_findings[0]["severity"] == "critical"
    assert "_novelty_gate_reason" not in result_findings[0]


# ---------------------------------------------------------------------------
# Test 5: missing relation field defaults to NEW_INTRODUCED (gets downgraded)
# ---------------------------------------------------------------------------
def test_novelty_gate_defaults_missing_relation_to_new_introduced():
    # No 'relation' key in finding at all
    finding = {"severity": "critical", "cited_lines": ["other.py:99"]}
    defenses = []
    diff_text = "some diff"

    result_findings, _stats = _apply_novelty_gate(
        findings=[finding],
        defenses=defenses,
        diff_text=diff_text,
        cycle_number=2,
    )

    assert result_findings[0]["severity"] == "suggestion"
    assert result_findings[0].get("_novelty_gate_reason") == "unjustified-novelty-claim"


# ---------------------------------------------------------------------------
# Test 6: stats dict returned with expected keys and counts
# ---------------------------------------------------------------------------
def test_novelty_gate_returns_relation_distribution_stats():
    # 2 NEW_INTRODUCED: one justified (proximity), one not
    finding_ni_justified = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["runner.py:10"],
        severity="critical",
    )
    defense = {"cited_lines": ["runner.py:11"]}  # proximity anchor

    finding_ni_unjustified = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["other.py:200"],
        severity="critical",
    )
    finding_resustain = _make_finding(
        relation="RESUSTAIN_OF",
        cited_lines=["runner.py:5"],
        severity="important",
    )
    finding_reframe = _make_finding(
        relation="REFRAME_OF",
        cited_lines=["runner.py:5"],
        severity="suggestion",
    )

    _result_findings, stats = _apply_novelty_gate(
        findings=[
            finding_ni_justified,
            finding_ni_unjustified,
            finding_resustain,
            finding_reframe,
        ],
        defenses=[defense],
        diff_text="some diff",
        cycle_number=2,
    )

    assert "new_introduced_justified" in stats
    assert "new_introduced_unjustified" in stats
    assert "resustain_of_count" in stats
    assert "reframe_of_count" in stats
    assert stats["resustain_of_count"] == 1
    assert stats["reframe_of_count"] == 1


# ---------------------------------------------------------------------------
# Test 7: escape_rationale fails criterion 1 (token not in diff)
# ---------------------------------------------------------------------------
def test_criterion1_token_absent_from_diff_fails():
    finding = _make_finding(
        relation="NEW_INTRODUCED",
        cited_lines=["other.py:20"],
        severity="critical",
        escape_rationale="some_func is missing from new file",
    )
    defenses = []
    diff_text = "completely different content"  # "some_func" not in diff

    result_findings, _stats = _apply_novelty_gate(
        findings=[finding],
        defenses=defenses,
        diff_text=diff_text,
        cycle_number=2,
    )

    assert result_findings[0]["severity"] == "suggestion"
    assert result_findings[0].get("_novelty_gate_reason") == "unjustified-novelty-claim"


# ---------------------------------------------------------------------------
# Test 8: all NEW_INTRODUCED findings downgraded when no defenses
# ---------------------------------------------------------------------------
def test_novelty_gate_no_defenses_downgrades_all_new_introduced():
    findings = [
        _make_finding(
            relation="NEW_INTRODUCED",
            cited_lines=[f"file.py:{i * 10}"],
            severity="critical",
        )
        for i in range(1, 4)
    ]
    defenses = []
    diff_text = "some diff"

    result_findings, _stats = _apply_novelty_gate(
        findings=findings,
        defenses=defenses,
        diff_text=diff_text,
        cycle_number=2,
    )

    assert len(result_findings) == 3
    for f in result_findings:
        assert f["severity"] == "suggestion"
        assert f.get("_novelty_gate_reason") == "unjustified-novelty-claim"


# ---------------------------------------------------------------------------
# Test 9 (T2 RED): PR-102 cycle-2 new-file regression replay
# ---------------------------------------------------------------------------
def test_pr102_new_file_findings_all_downgraded():
    """Replay test: PR-102 cycle 2 new-file findings should all be downgraded."""
    import json

    fixtures_dir = pathlib.Path(__file__).parent.parent.parent / "fixtures"
    findings = [
        json.loads(line)
        for line in (fixtures_dir / "pr-102-cycle-2-new-file-findings.jsonl")
        .read_text()
        .splitlines()
        if line.strip()
    ]
    defenses = [
        json.loads(line)
        for line in (fixtures_dir / "pr-102-cycle-1-defenses.jsonl")
        .read_text()
        .splitlines()
        if line.strip()
    ]

    result, stats = _apply_novelty_gate(
        findings, defenses, diff_text="", cycle_number=2
    )
    downgraded = [f for f in result if f.get("severity") == "suggestion"]
    assert len(downgraded) == len(findings), (
        f"Expected 100% downgraded, got {len(downgraded)}/{len(findings)}"
    )


# ---------------------------------------------------------------------------
# Test 10 (RED): novelty gate is skipped when DSO_SUPPRESS_PRIOR_DEFENSES=true
# Bug 10ea-645f-d11e-4160: the caller-level guard at runner.py line 2523
# runs unconditionally on cycle_number >= 2, even when suppress is true.
# This causes NEW_INTRODUCED findings to be downgraded to "suggestion"
# during integration review when they should retain original severity.
# ---------------------------------------------------------------------------
def test_novelty_gate_skipped_when_suppress_prior_defenses(tmp_path):
    """When DSO_SUPPRESS_PRIOR_DEFENSES=true and cycle_number >= 2, the novelty
    gate must NOT run, so findings retain their original severity.

    This exercises runner.main() end-to-end (with mocked LLM dispatch) to
    verify the caller-level guard, not just _apply_novelty_gate in isolation.
    """
    import contextlib
    import json
    import sys

    from unittest.mock import patch as _patch

    _REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
    _SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
    if _SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, _SCRIPTS_DIR)

    import dso_ci_review.runner as runner_mod

    # Specialist findings: one NEW_INTRODUCED with "important" severity.
    # If the novelty gate runs with empty defenses, this gets downgraded to
    # "suggestion". If the guard correctly skips the gate, it stays "important".
    specialist_findings = [
        {
            "findings": [
                {
                    "severity": "important",
                    "description": "Missing null check in integration path",
                    "cited_lines": ["src/handler.py:42"],
                    "category": "correctness",
                    "relation": "NEW_INTRODUCED",
                }
            ],
            "scores": {},
            "summary": "important issue",
        }
    ]

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

    diff_file = tmp_path / "input.diff"
    diff_file.write_text("diff --git a/src/handler.py b/src/handler.py\n+added line\n")
    output_file = tmp_path / "findings.json"

    env = {
        "DSO_CI_REVIEW_DIFF_PATH": str(diff_file),
        "DSO_CI_REVIEW_OUTPUT_PATH": str(output_file),
        "CI_REVIEW_PROVIDER": "anthropic",
        "ANTHROPIC_API_KEY": "test-key",
        "DSO_REVIEW_CYCLE": "2",
        "DSO_SUPPRESS_PRIOR_DEFENSES": "true",
    }

    empty_ledger = {"schema_version": "1.1.0", "epic_id": "", "cycles": []}

    async def mock_dispatch(agents):
        return specialist_findings

    dispatch_next = {
        "action": "DISPATCH_NEXT",
        "reason": "cycle 2 in progress",
        "cycle_num": 2,
    }

    stack = contextlib.ExitStack()
    stack.enter_context(_patch.dict("os.environ", env))
    stack.enter_context(
        _patch(
            "dso_ci_review.runner._classify_tier_via_bash",
            return_value=_TIER_RESULT,
        )
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.runner._validate_findings_schema",
            return_value=runner_mod._SchemaValidationResult("schema_pass", []),
        )
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.runner.async_dispatch_specialists",
            side_effect=mock_dispatch,
        )
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.verifier.dispatch_verifier",
            side_effect=lambda findings, reviewed_sha=None: findings,
        )
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.runner.cycle_next_action",
            return_value=dispatch_next,
        )
    )
    stack.enter_context(
        _patch(
            "dso_ci_review.runner._resolve_artifacts_dir",
            return_value=str(tmp_path),
        )
    )
    # Return cycle_number=2 from ledger init to trigger the novelty gate path
    stack.enter_context(
        _patch(
            "dso_ci_review.runner._init_cycle_ledger",
            return_value=(empty_ledger, 2),
        )
    )
    stack.enter_context(
        _patch("dso_ci_review.runner._resolve_max_cycles", return_value=3)
    )
    stack.enter_context(
        _patch("dso_ci_review.runner._resolve_pr_number", return_value=None)
    )
    stack.enter_context(
        _patch("dso_ci_review.runner._resolve_repo", return_value=None)
    )
    stack.enter_context(_patch("dso_ci_review.runner._append_cycle"))
    stack.enter_context(_patch("dso_ci_review.runner._post_cycle_marker_comment"))
    stack.enter_context(
        _patch(
            "dso_ci_review.runner.subprocess.check_output",
            return_value="abc123\n",
        )
    )

    with stack:
        runner_mod.main()

    # Read the output findings and check severity was NOT downgraded
    assert output_file.exists(), "runner.main() did not write output file"
    output_data = json.loads(output_file.read_text())
    findings = output_data.get("findings", [])

    # The finding must exist and retain its original "important" severity.
    # BUG (RED): the novelty gate runs unconditionally on cycle >= 2,
    # downgrades the NEW_INTRODUCED finding to "suggestion" because
    # defenses are empty (suppressed). After the fix, the guard at line 2523
    # will check _suppress_prior_defenses and skip the gate.
    assert len(findings) >= 1, f"Expected at least 1 finding, got {len(findings)}"
    severity_values = [f.get("severity") for f in findings]
    assert "important" in severity_values, (
        f"Expected finding to retain 'important' severity when "
        f"DSO_SUPPRESS_PRIOR_DEFENSES=true, but got severities: {severity_values}. "
        f"This indicates the novelty gate ran when it should have been skipped."
    )
