"""RED tests for REVIEW-WORKFLOW.md cycle-K auto-dispatch and Jaccard stability halt.

Testing mode: RED — REVIEW-WORKFLOW.md does not yet contain the cycle-K dispatch
section or Jaccard halt logic. All tests MUST fail until task ddfc-532a implements
the workflow update.

Behavioral contracts under test:
1. STABLE_HALT signal and Jaccard >= 0.85 threshold documented.
2. Jaccard < 0.85 results in auto-dispatch of next cycle without user prompt.
3. Zero-set edge case: Jaccard = 1.0 when either finding set empty → halt.
4. Finding identity uses stable hash fields (file, line_range/cited_lines, category).
5. Jaccard computation is identical for local (cycle-ledger.json) and CI (PR comments) paths.
6. oscillation_no_arbiter_engagement gate scope clarified: inner resolution attempts vs outer cycle counter.
7. Next cycle auto-dispatched without requiring user input.
"""

import pathlib
import re

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_WORKFLOW_FILE = (
    _REPO_ROOT / "plugins" / "dso" / "docs" / "workflows" / "REVIEW-WORKFLOW.md"
)


def _load_workflow() -> str:
    return _WORKFLOW_FILE.read_text(encoding="utf-8")


def test_jaccard_stable_halt_signal_documented():
    """REVIEW-WORKFLOW.md contains STABLE_HALT signal for Jaccard >= 0.85 finding stability."""
    content = _load_workflow()
    assert re.search(r"STABLE_HALT", content), (
        "REVIEW-WORKFLOW.md must document STABLE_HALT signal for Jaccard >= 0.85 halt"
    )
    assert re.search(r">=\s*0\.85|≥\s*0\.85", content), (
        "REVIEW-WORKFLOW.md must specify Jaccard threshold >= 0.85"
    )


def test_jaccard_continuation_documented():
    """REVIEW-WORKFLOW.md states Jaccard < 0.85 results in cycle continuation."""
    content = _load_workflow()
    assert re.search(r"auto.dispatch|auto dispatch", content, re.IGNORECASE), (
        "REVIEW-WORKFLOW.md must document auto-dispatch of next cycle when Jaccard < 0.85"
    )


def test_zero_set_edge_case_documented():
    """REVIEW-WORKFLOW.md handles zero-set Jaccard edge case as similarity = 1.0."""
    content = _load_workflow()
    assert re.search(
        r"Jaccard.*1\.0|1\.0.*Jaccard"
        r"|zero.set.*Jaccard|Jaccard.*zero.set"
        r"|Jaccard.*empty.*set|empty.*set.*Jaccard"
        r"|Jaccard.*zero.*finding|zero.*finding.*Jaccard",
        content,
        re.IGNORECASE,
    ), (
        "REVIEW-WORKFLOW.md must document zero-set Jaccard edge case: "
        "when either finding set is empty, Jaccard = 1.0 → STABLE_HALT"
    )


def test_finding_identity_normalization_documented():
    """REVIEW-WORKFLOW.md documents finding identity as stable hash for Jaccard computation."""
    content = _load_workflow()
    assert re.search(
        r"Jaccard.*(?:line_range|finding_hash|identity|normali)"
        r"|(?:line_range|finding_hash|identity|normali).*Jaccard"
        r"|finding.*identity.*(?:file|category|hash)"
        r"|(?:file|category|hash).*finding.*identity",
        content,
        re.IGNORECASE,
    ), (
        "REVIEW-WORKFLOW.md must document finding identity normalization for Jaccard computation "
        "(fields: file, line_range/cited_lines, category used as stable identity key)"
    )


def test_local_ci_parity_documented():
    """REVIEW-WORKFLOW.md states Jaccard computation is identical for local and CI paths."""
    content = _load_workflow()
    assert re.search(
        r"Jaccard.*(?:parity|identical|local.*CI|CI.*local|cycle.ledger.*PR|PR.*cycle.ledger)"
        r"|(?:parity|identical|local.*CI|CI.*local|cycle.ledger.*PR|PR.*cycle.ledger).*Jaccard",
        content,
        re.IGNORECASE,
    ), (
        "REVIEW-WORKFLOW.md must document local/CI Jaccard computation parity "
        "(same computation for cycle-ledger.json local path and CI PR-comments path)"
    )


def test_oscillation_gate_scope_clarified():
    """REVIEW-WORKFLOW.md clarifies oscillation gate scope: inner loop vs outer cycle counter."""
    content = _load_workflow()
    assert re.search(
        r"outer loop|inner loop|outer cycle|inner.*resolution|max_cycles.*max_resolution|max_resolution.*max_cycles",
        content,
        re.IGNORECASE,
    ), (
        "REVIEW-WORKFLOW.md must clarify oscillation_no_arbiter_engagement scope: inner resolution attempts vs outer cycle count"
    )


def test_auto_dispatch_without_user_prompt():
    """REVIEW-WORKFLOW.md documents that cycle K+1 is auto-dispatched without user input."""
    content = _load_workflow()
    assert re.search(
        r"cycle.*K\+1.*auto.dispatch|auto.dispatch.*cycle.*K\+1"
        r"|next cycle.*auto.dispatch|auto.dispatch.*next cycle"
        r"|cycle.*K.*without.*user|without.*user.*cycle.*K"
        r"|Jaccard.*auto.dispatch|auto.dispatch.*Jaccard",
        content,
        re.IGNORECASE,
    ), (
        "REVIEW-WORKFLOW.md must document that cycle K+1 is auto-dispatched without user prompt "
        "when Jaccard < 0.85"
    )
