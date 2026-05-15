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

    with patch(
        "dso_ci_review.proximity.validate_escape_rationale", return_value=True
    ):
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
            cited_lines=[f"file.py:{i*10}"],
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
    findings = [json.loads(l) for l in (fixtures_dir / "pr-102-cycle-2-new-file-findings.jsonl").read_text().splitlines() if l.strip()]
    defenses = [json.loads(l) for l in (fixtures_dir / "pr-102-cycle-1-defenses.jsonl").read_text().splitlines() if l.strip()]

    result, stats = _apply_novelty_gate(findings, defenses, diff_text="", cycle_number=2)
    downgraded = [f for f in result if f.get("severity") == "suggestion"]
    assert len(downgraded) == len(findings), f"Expected 100% downgraded, got {len(downgraded)}/{len(findings)}"
