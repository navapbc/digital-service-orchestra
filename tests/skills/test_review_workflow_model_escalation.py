"""Tests for review model escalation in REVIEW-WORKFLOW.md.

Bug e85c-8492: Sprint orchestrator does not escalate review model after
repeated failed reviews. The re-review dispatch always uses "the same
named agent from Step 3" with no model upgrade on subsequent attempts.

These tests verify the instruction-level fix:
1. Re-review dispatch section contains a model escalation table/rule
2. The escalation specifies concrete agent upgrades (light→standard→opus)
3. The escalation is tied to REVIEW_PASS_NUM (the existing pass counter)
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
REVIEW_WORKFLOW_MD = (
    REPO_ROOT / "plugins" / "dso" / "docs" / "workflows" / "REVIEW-WORKFLOW.md"
)


def _read_workflow() -> str:
    return REVIEW_WORKFLOW_MD.read_text()


def _extract_bash_re_review_conditional(content: str) -> str:
    """Extract the bash code block containing RE_REVIEW_DEEP_FULL logic."""
    pattern = re.compile(
        r"```bash\n\s*# Re-review model escalation logic.*?```",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def _extract_re_review_dispatch(content: str) -> str:
    """Extract the re-review dispatch section (after FIXES_APPLIED).

    This is the specific section that says 'Dispatch the re-review sub-agent
    using the same named agent from Step 3' — the section that needs the
    model escalation rule added.
    """
    pattern = re.compile(
        r"When `RESOLUTION_RESULT: FIXES_APPLIED`.*?(?=\n####|\n## |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def test_re_review_dispatch_has_model_escalation_table() -> None:
    """The re-review dispatch section must contain a model escalation table."""
    content = _read_workflow()
    section = _extract_re_review_dispatch(content)

    assert section, (
        "Expected to find 'When RESOLUTION_RESULT: FIXES_APPLIED' section "
        "in REVIEW-WORKFLOW.md but none was found."
    )

    # Must contain a concrete re-review model escalation rule
    # (not just general "escalate to user" language)
    assert re.search(
        r"re-review.*model.*escalat|model.*escalat.*re-review"
        r"|re-review.*upgrade|upgrade.*re-review"
        r"|Pass\s+1.*REVIEW_AGENT.*Pass\s+2"
        r"|REVIEW_PASS_NUM.*upgrade|REVIEW_PASS_NUM.*escalat",
        section,
        re.IGNORECASE,
    ), (
        "Expected the re-review dispatch section (after FIXES_APPLIED) to contain "
        "a model escalation rule tied to re-review pass number. Currently the section "
        "says 'Dispatch the re-review sub-agent using the same named agent from Step 3' "
        "with no upgrade path on repeated failures."
    )


def test_re_review_escalation_specifies_light_to_standard() -> None:
    """The re-review escalation must specify light→standard upgrade."""
    content = _read_workflow()
    section = _extract_re_review_dispatch(content)

    assert section, "Expected to find 'When RESOLUTION_RESULT: FIXES_APPLIED' section."

    # Must mention upgrading light to standard specifically
    assert re.search(
        r"light.*(?:→|->|to|upgrade).*standard"
        r"|code-reviewer-light.*code-reviewer-standard",
        section,
        re.IGNORECASE,
    ), (
        "Expected the re-review model escalation to specify upgrading from "
        "light (haiku) to standard (sonnet). Light-tier reviewers produce "
        "recurring false positives on REVIEW-DEFENSE comments that higher-tier "
        "reviewers understand."
    )


def test_re_review_escalation_specifies_standard_to_opus() -> None:
    """The re-review escalation must specify standard→opus upgrade."""
    content = _read_workflow()
    section = _extract_re_review_dispatch(content)

    assert section, "Expected to find 'When RESOLUTION_RESULT: FIXES_APPLIED' section."

    # Must mention upgrading standard to opus on further failures
    assert re.search(
        r"standard.*(?:→|->|to|upgrade).*opus"
        r"|code-reviewer-standard.*(?:code-reviewer-deep-arch|opus)",
        section,
        re.IGNORECASE,
    ), (
        "Expected the re-review model escalation to specify upgrading to opus "
        "on attempt 3+. This mirrors the commit workflow's test failure delegation "
        "pattern (Attempt 1: sonnet, Attempt 2+: opus)."
    )


def test_deep_tier_re_review_always_uses_full_pipeline() -> None:
    """Deep tier re-review must set RE_REVIEW_DEEP_FULL=true at any pass >= 2.

    Bug d7e6-216a: At REVIEW_PASS_NUM=2 with REVIEW_TIER=deep, RE_REVIEW_DEEP_FULL
    stayed false because the guard only fired at >= 3. The Otherwise branch then
    dispatched only opus arch without the 3 prerequisite sonnet agents.
    """
    content = _read_workflow()
    bash_block = _extract_bash_re_review_conditional(content)

    assert bash_block, (
        "Expected to find bash code block starting with '# Re-review model escalation "
        "logic' in REVIEW-WORKFLOW.md."
    )

    # The bash conditional must have a branch that handles REVIEW_TIER == deep
    # at REVIEW_PASS_NUM >= 2 (not just >= 3) and sets RE_REVIEW_DEEP_FULL=true.
    # This means there must be a line that checks for REVIEW_TIER == "deep"
    # within a REVIEW_PASS_NUM >= 2 branch.
    has_deep_at_pass_2 = re.search(
        r'REVIEW_PASS_NUM.*-ge\s+2.*REVIEW_TIER.*==.*"deep".*RE_REVIEW_DEEP_FULL=true'
        r'|REVIEW_TIER.*==.*"deep".*RE_REVIEW_DEEP_FULL=true',
        bash_block,
        re.DOTALL,
    )
    # Verify the deep-tier branch is NOT only at >= 3 by checking that
    # the block contains a branch where deep specifically triggers full pipeline
    # separate from the >= 3 catch-all
    has_deep_specific_branch = re.search(
        r'elif.*REVIEW_TIER.*==.*"deep".*\n.*RE_REVIEW_DEEP_FULL=true'
        r"|elif.*REVIEW_PASS_NUM.*-ge\s+2.*&&.*REVIEW_TIER.*==.*\"deep\"",
        bash_block,
    )
    assert has_deep_at_pass_2 or has_deep_specific_branch, (
        "Expected the bash re-review conditional to contain a branch that sets "
        "RE_REVIEW_DEEP_FULL=true when REVIEW_TIER=deep at REVIEW_PASS_NUM >= 2. "
        "Currently the conditional only sets RE_REVIEW_DEEP_FULL=true at >= 3, "
        "leaving deep tier at pass 2 unhandled — causing opus arch to be dispatched "
        "without the 3 prerequisite sonnet reviews."
    )
