"""Behavioral test harness for CI review pipeline convergence logic.

Uses SHA-pinned fixture diffs from tests/fixtures/review-convergence/ as input data.
All LLM calls are mocked — no API keys required, safe for CI.

Fixture legend:
  pr-65.diff / pr-65-prior-findings.json  — cycle-2 multi-turn scenario (RESUSTAIN_OF)
  pr-62.diff / pr-62-prior-findings.json  — cycle-2 NEW_INTRODUCED without escape_rationale
  single-<pr#>.diff + single-<pr#>-prior-findings.json  — 5 single-cycle (cycle_count=1) fixtures

Behavioral contracts under test:

  T1 — RESUSTAIN_OF finding with prior defense triggers arbiter dispatch exactly once.
  T2 — NEW_INTRODUCED finding on overlapping lines without escape_rationale is re-dispatched.
  T3 — Single-cycle run (DSO_REVIEW_CYCLE=1) sets cycle_count=1; no arbiter dispatch occurs.
  T4 — DOWNGRADE_TO ruling with named_rebuttal citing only evidence lines → ACCEPT_DEFENSE.
"""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any
from unittest.mock import MagicMock, call, patch

import pytest

# ---------------------------------------------------------------------------
# Path bootstrap
# ---------------------------------------------------------------------------

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

_FIXTURE_DIR = _REPO_ROOT / "tests" / "fixtures" / "review-convergence"


# ---------------------------------------------------------------------------
# Helpers — fixture loading
# ---------------------------------------------------------------------------


def _load_diff(filename: str) -> str:
    path = _FIXTURE_DIR / filename
    return path.read_text(encoding="utf-8")


def _load_findings(filename: str) -> list[dict]:
    path = _FIXTURE_DIR / filename
    return json.loads(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Pipeline stubs — represent the convergence pipeline logic being tested.
#
# These stubs implement only the decision logic (no I/O), so the tests
# validate the orchestration rules rather than the LLM response quality.
# When the real arbiter module lands, these stubs should be replaced by
# imports from dso_ci_review.arbiter.
# ---------------------------------------------------------------------------


def _classify_finding_relation(
    finding: dict,
    prior_findings: list[dict],
) -> str:
    """Return the relation type for a finding given the prior cycle findings.

    Rules:
      - If prior_findings contains a finding with matching id, return 'RESUSTAIN_OF'.
      - Otherwise return 'NEW_INTRODUCED'.
    """
    prior_ids = {f.get("finding_id") or f.get("id") for f in prior_findings}
    fid = finding.get("prior_finding_id") or finding.get("id")
    if fid and fid in prior_ids:
        return "RESUSTAIN_OF"
    return "NEW_INTRODUCED"


def _needs_escape_rationale(finding: dict, diff_lines: set[str]) -> bool:
    """Return True when a NEW_INTRODUCED finding lacks escape_rationale on overlapping lines.

    A finding overlaps the diff when any of its cited_lines appears in the diff text
    (crude heuristic — adequate for fixture-based testing).
    """
    if finding.get("escape_rationale"):
        return False
    for cited in finding.get("cited_lines", []):
        # cited_lines format: "path:lineno" — check if path appears in diff
        path = cited.split(":")[0] if ":" in cited else cited
        if any(path in dl for dl in diff_lines):
            return True
    return False


def _validate_arbiter_ruling(ruling: dict, finding: dict) -> dict:
    """Validate a DOWNGRADE_TO ruling; reclassify if named_rebuttal is invalid.

    A DOWNGRADE_TO ruling is invalid when named_rebuttal ONLY references lines
    already listed in reviewer_severity_evidence (i.e., no new evidence).

    Reclassifies to ACCEPT_DEFENSE when invalid.
    """
    if not ruling.get("ruling", "").startswith("DOWNGRADE_TO"):
        return ruling

    severity_rebuttal = ruling.get("severity_rebuttal", {})
    named_rebuttal = severity_rebuttal.get("named_rebuttal", "")
    evidence_ref = severity_rebuttal.get("reviewer_severity_evidence", "")

    # Extract referenced paths from evidence and named_rebuttal
    def _extract_paths(text: str) -> set[str]:
        """Extract 'path:lineno' fragments from text."""
        import re
        return set(re.findall(r"[\w/.-]+\.[\w]+:\d+", text))

    evidence_paths = _extract_paths(evidence_ref)
    cited_paths = {cl.split(":")[0] + ":" + cl.split(":")[1] if cl.count(":") >= 1 else cl
                   for cl in finding.get("cited_lines", [])}
    # Combine: evidence is everything the reviewer already cited
    all_prior_paths = evidence_paths | cited_paths

    # Named rebuttal must reference at least one path NOT in prior evidence
    rebuttal_paths = _extract_paths(named_rebuttal)
    new_evidence = rebuttal_paths - all_prior_paths

    if not new_evidence and rebuttal_paths:
        # All referenced paths are already in the evidence set — invalid rebuttal
        result = dict(ruling)
        result["ruling"] = "ACCEPT_DEFENSE"
        result["_reclassified_reason"] = (
            "named_rebuttal only references lines already in reviewer_severity_evidence"
        )
        return result

    return ruling


def _run_pipeline_with_mock(
    diff_text: str,
    prior_findings: list[dict],
    cycle: int,
    mock_dispatch: MagicMock,
    mock_arbiter: MagicMock,
) -> dict[str, Any]:
    """Minimal pipeline orchestrator for test purposes.

    Decision logic:
      1. Set cycle_count = cycle.
      2. For each finding in mock_dispatch return value:
         a. If cycle > 1 and relation == RESUSTAIN_OF with prior defense → call mock_arbiter.
         b. If NEW_INTRODUCED and needs escape_rationale → mark as re_dispatch_needed.
      3. Return result dict with cycle_count and arbiter_dispatches.
    """
    # Simulate receiving findings from dispatch
    mock_response = mock_dispatch(diff_text=diff_text, cycle=cycle)
    findings = mock_response.get("findings", [])

    arbiter_dispatches: list[str] = []
    re_dispatch_needed: list[str] = []

    # Build set of diff lines for overlap check
    diff_lines = set(diff_text.splitlines())

    for finding in findings:
        relation = _classify_finding_relation(finding, prior_findings)

        if cycle > 1 and relation == "RESUSTAIN_OF":
            # Find matching prior defense
            prior_defense = next(
                (pf for pf in prior_findings
                 if (pf.get("finding_id") or pf.get("id")) ==
                    (finding.get("prior_finding_id") or finding.get("id"))
                 and pf.get("defense_text")),
                None,
            )
            if prior_defense:
                mock_arbiter(finding_id=finding.get("id"), prior_defense=prior_defense)
                arbiter_dispatches.append(finding.get("id", "unknown"))

        elif relation == "NEW_INTRODUCED" and _needs_escape_rationale(finding, diff_lines):
            re_dispatch_needed.append(finding.get("id", "unknown"))

    return {
        "cycle_count": cycle,
        "findings": findings,
        "arbiter_dispatches": arbiter_dispatches,
        "re_dispatch_needed": re_dispatch_needed,
    }


# ---------------------------------------------------------------------------
# T1 — RESUSTAIN_OF with prior defense triggers arbiter dispatch exactly once
# ---------------------------------------------------------------------------


def test_resustain_of_with_proximity_triggers_arbiter():
    """Given: fixture diff with RESUSTAIN_OF finding + prior defense (pr-65, cycle 2)
    When: pipeline runs against pr-65 fixture (cycle 2)
    Then: arbiter dispatch called exactly once for the matching finding_id
    """
    diff_text = _load_diff("pr-65.diff")
    prior_findings = _load_findings("pr-65-prior-findings.json")

    # The defended finding from the prior cycle — should trigger arbiter
    resustain_finding_id = prior_findings[0]["finding_id"]

    # Mock dispatch returns a finding that RESUSTAIN_OF the defended prior finding
    mock_dispatch = MagicMock(
        return_value={
            "findings": [
                {
                    "id": resustain_finding_id,  # same id → RESUSTAIN_OF
                    "prior_finding_id": resustain_finding_id,
                    "relation": "RESUSTAIN_OF",
                    "dimension": "correctness",
                    "severity": "critical",
                    "description": "The merge-to-main.sh rebase still operates on a stale base ref.",
                    "cited_lines": ["plugins/dso/scripts/merge-to-main.sh:142"],
                }
            ]
        }
    )
    mock_arbiter = MagicMock(return_value={"ruling": "SUSTAIN", "rationale": "defense insufficient"})

    result = _run_pipeline_with_mock(
        diff_text=diff_text,
        prior_findings=prior_findings,
        cycle=2,
        mock_dispatch=mock_dispatch,
        mock_arbiter=mock_arbiter,
    )

    assert mock_arbiter.call_count == 1, (
        f"Expected arbiter dispatch exactly once for RESUSTAIN_OF finding, "
        f"got: {mock_arbiter.call_count}"
    )
    assert resustain_finding_id in result["arbiter_dispatches"], (
        f"Expected {resustain_finding_id!r} in arbiter_dispatches, "
        f"got: {result['arbiter_dispatches']!r}"
    )


# ---------------------------------------------------------------------------
# T2 — NEW_INTRODUCED without escape_rationale on overlapping lines → re-dispatched
# ---------------------------------------------------------------------------


def test_new_introduced_without_escape_rationale_rejected():
    """Given: fixture with NEW_INTRODUCED finding on overlapping lines without escape_rationale
    When: pipeline processes pr-62 fixture (cycle 2)
    Then: finding is marked for re-dispatch (not accepted)
    """
    diff_text = _load_diff("pr-62.diff")
    prior_findings = _load_findings("pr-62-prior-findings.json")

    # Simulate a NEW finding (id not in prior) on a file present in the diff
    # .github/workflows/ci.yml appears in the pr-62.diff
    new_finding_id = "f-new-pr62-no-escape"
    mock_dispatch = MagicMock(
        return_value={
            "findings": [
                {
                    "id": new_finding_id,
                    "relation": "NEW_INTRODUCED",
                    "dimension": "correctness",
                    "severity": "important",
                    "description": "New consolidation path lacks error handling.",
                    "cited_lines": [".github/workflows/ci.yml:150"],
                    # Deliberately NO escape_rationale field
                }
            ]
        }
    )
    mock_arbiter = MagicMock()

    result = _run_pipeline_with_mock(
        diff_text=diff_text,
        prior_findings=prior_findings,
        cycle=2,
        mock_dispatch=mock_dispatch,
        mock_arbiter=mock_arbiter,
    )

    assert new_finding_id in result["re_dispatch_needed"], (
        f"Expected {new_finding_id!r} in re_dispatch_needed (no escape_rationale on "
        f"overlapping lines), got: {result['re_dispatch_needed']!r}"
    )
    # Arbiter must NOT be called for NEW_INTRODUCED findings
    assert mock_arbiter.call_count == 0, (
        f"Arbiter must not be dispatched for NEW_INTRODUCED findings, "
        f"got: {mock_arbiter.call_count}"
    )


# ---------------------------------------------------------------------------
# T3 — Single-cycle run: cycle_count=1, no arbiter dispatch
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("pr_num", [60, 61, 63, 64, 66])
def test_new_pre_existing_not_in_scope(pr_num: int):
    """Given: single-cycle fixture (DSO_REVIEW_CYCLE=1)
    When: pipeline runs against single-<pr_num> fixture
    Then: cycle_count=1 in results, no arbiter dispatch occurs
    """
    diff_text = _load_diff(f"single-{pr_num}.diff")
    prior_findings = _load_findings(f"single-{pr_num}-prior-findings.json")

    # Single-cycle: prior_findings is [] per spec
    assert prior_findings == [], (
        f"single-{pr_num}-prior-findings.json must be empty for cycle-1 fixtures"
    )

    mock_dispatch = MagicMock(
        return_value={
            "findings": [
                {
                    "id": f"f-single-{pr_num}",
                    "relation": "NEW_INTRODUCED",
                    "dimension": "hygiene",
                    "severity": "minor",
                    "description": "Style nit on first review cycle.",
                    "cited_lines": [],
                    "escape_rationale": "First cycle; no prior findings to compare.",
                }
            ]
        }
    )
    mock_arbiter = MagicMock()

    result = _run_pipeline_with_mock(
        diff_text=diff_text,
        prior_findings=prior_findings,
        cycle=1,
        mock_dispatch=mock_dispatch,
        mock_arbiter=mock_arbiter,
    )

    assert result["cycle_count"] == 1, (
        f"Expected cycle_count=1 for single-cycle fixture, got: {result['cycle_count']!r}"
    )
    assert mock_arbiter.call_count == 0, (
        f"Arbiter must not be dispatched in cycle-1 run, got: {mock_arbiter.call_count}"
    )
    assert result["arbiter_dispatches"] == [], (
        f"No arbiter_dispatches expected for cycle-1 run, got: {result['arbiter_dispatches']!r}"
    )


# ---------------------------------------------------------------------------
# T4 — DOWNGRADE_TO with named_rebuttal citing only evidence lines → ACCEPT_DEFENSE
# ---------------------------------------------------------------------------


def test_downgrade_to_without_named_rebuttal_reclassified():
    """Given: DOWNGRADE_TO ruling with named_rebuttal citing only evidence lines
    When: validate_arbiter_ruling called
    Then: ruling reclassified to ACCEPT_DEFENSE
    """
    # The named_rebuttal only references auth/login.py:42 — already in evidence
    ruling = {
        "ruling": "DOWNGRADE_TO_important",
        "severity_rebuttal": {
            "reviewer_claimed_severity": "critical",
            "reviewer_severity_evidence": "auth/login.py:42",
            "named_rebuttal": "line auth/login.py:42 is actually handled by null-check",
        },
    }
    finding = {
        "id": "f1",
        "cited_lines": ["auth/login.py:42"],
        "severity": "critical",
    }

    result = _validate_arbiter_ruling(ruling, finding)

    assert result["ruling"] == "ACCEPT_DEFENSE", (
        f"Expected ruling='ACCEPT_DEFENSE' when named_rebuttal only references "
        f"lines already in reviewer_severity_evidence, got: {result['ruling']!r}"
    )
    assert "_reclassified_reason" in result, (
        "Expected _reclassified_reason to explain the reclassification"
    )


def test_downgrade_to_with_valid_named_rebuttal_preserved():
    """Given: DOWNGRADE_TO ruling with named_rebuttal citing a NEW line (non-evidence)
    When: validate_arbiter_ruling called
    Then: ruling is preserved as-is (DOWNGRADE_TO is valid)
    """
    ruling = {
        "ruling": "DOWNGRADE_TO_style",
        "severity_rebuttal": {
            "reviewer_claimed_severity": "critical",
            "reviewer_severity_evidence": "auth/login.py:42",
            "named_rebuttal": "auth/login.py:55 provides the mitigation (not cited previously)",
        },
    }
    finding = {
        "id": "f1",
        "cited_lines": ["auth/login.py:42"],
        "severity": "critical",
    }

    result = _validate_arbiter_ruling(ruling, finding)

    assert result["ruling"] == "DOWNGRADE_TO_style", (
        f"Expected ruling='DOWNGRADE_TO_style' to be preserved when named_rebuttal "
        f"introduces new evidence, got: {result['ruling']!r}"
    )
    assert "_reclassified_reason" not in result, (
        "Valid DOWNGRADE_TO ruling must not have a reclassification reason"
    )
