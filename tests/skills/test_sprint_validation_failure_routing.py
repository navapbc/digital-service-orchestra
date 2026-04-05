"""Tests for Step 10a validation failure branching in sprint SKILL.md.

Story 758c-6993 DD4: Structural Python test for Step 10a validation failure
branching (lines 1257-1275).

These tests assert:
1. The validation failure branching section exists in SKILL.md (Step 10a contains
   a "Story validation failure detection" or equivalent branching block).
2. REPLAN_TRIGGER: validation command is present in Step 10a.
3. Implementation-plan re-invocation is specified in Step 10a.
4. The story is not closed while the done definition is failing (Do NOT close
   the story instruction is present).
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def _extract_step_10a(content: str) -> str:
    """Extract Step 10a section from SKILL.md."""
    pattern = re.compile(
        r"### Step 10a:.*?(?=\n### |\n## |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def test_validation_failure_branching_section_exists() -> None:
    """Assertion 1: Step 10a must contain a validation failure branching section.

    The section should describe what to do when overall_verdict is FAIL,
    distinguishing between open tasks remaining vs. all tasks closed cases.
    """
    content = _read_skill()
    step_10a = _extract_step_10a(content)

    assert step_10a, "Expected to find Step 10a in SKILL.md but none was found."

    # Must contain explicit branching for the FAIL verdict case
    assert re.search(
        r"validation failure|overall_verdict.*FAIL|FAIL.*overall_verdict"
        r"|validation fails|validation failed",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to contain a validation failure branching section. "
        "When the completion-verifier returns overall_verdict: FAIL, the orchestrator "
        "needs explicit branching logic distinguishing open tasks vs. all-tasks-closed "
        "scenarios. No such branching section was found."
    )

    # Must describe the all-tasks-closed-but-validation-fails sub-case
    assert re.search(
        r"all tasks.*closed.*validation fail"
        r"|all tasks are closed.*fail"
        r"|tasks.*closed.*but.*fail"
        r"|closed.*no.*remaining.*task.*fail"
        r"|story.level done definition",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a validation failure branching to address the specific "
        "sub-case where all tasks are closed but the story-level done definition "
        "is still failing. This is distinct from the case where open tasks remain "
        "and requires different remediation (TDD remediation tasks via implementation-plan)."
    )


def test_replan_trigger_validation_command_present() -> None:
    """Assertion 2: REPLAN_TRIGGER: validation command must be present in Step 10a.

    The orchestrator must record a REPLAN_TRIGGER comment on the epic before
    re-invoking implementation-plan, so the audit trail exists even if re-planning fails.
    """
    content = _read_skill()
    step_10a = _extract_step_10a(content)

    assert step_10a, "Expected to find Step 10a in SKILL.md but none was found."

    # Must contain the REPLAN_TRIGGER keyword tied to validation
    assert re.search(
        r"REPLAN_TRIGGER.*validation|REPLAN_TRIGGER:.*validation",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to contain a 'REPLAN_TRIGGER: validation' command. "
        "This comment must be recorded on the epic before invoking implementation-plan "
        "so the audit trail exists even if re-planning fails. "
        "No REPLAN_TRIGGER: validation directive was found in Step 10a."
    )

    # Must show the ticket comment command syntax
    assert re.search(
        r"dso ticket comment.*REPLAN_TRIGGER"
        r"|REPLAN_TRIGGER.*dso ticket comment",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to show the '.claude/scripts/dso ticket comment' command "
        "for recording the REPLAN_TRIGGER. The audit trail comment must use the "
        "ticket CLI, not just describe logging to a file."
    )


def test_implementation_plan_reinvocation_specified() -> None:
    """Assertion 3: Step 10a must specify re-invoking /dso:implementation-plan on the story.

    When all tasks are closed but validation fails, the remediation path must
    re-invoke implementation-plan on the story to create TDD remediation tasks
    (new tasks only for uncovered success criteria — no duplication).
    """
    content = _read_skill()
    step_10a = _extract_step_10a(content)

    assert step_10a, "Expected to find Step 10a in SKILL.md but none was found."

    # Must mention implementation-plan re-invocation
    assert re.search(
        r"implementation.plan.*story"
        r"|re.invok.*implementation.plan"
        r"|invoke.*implementation.plan.*story"
        r"|/dso:implementation-plan",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to specify re-invoking /dso:implementation-plan on the story "
        "as the remediation path when all tasks are closed but validation fails. "
        "The implementation-plan re-invocation guard detects existing closed children "
        "and produces a diff plan (new tasks only). No such re-invocation was found."
    )

    # Must also reference the REPLAN_ESCALATE signal from implementation-plan
    assert re.search(
        r"REPLAN_ESCALATE",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to address the REPLAN_ESCALATE: brainstorm signal that "
        "implementation-plan may emit. When implementation-plan cannot satisfy success "
        "criteria, it escalates to brainstorm — Step 10a must handle this case "
        "rather than assuming implementation-plan always succeeds."
    )


def test_story_not_closed_while_validation_failing() -> None:
    """Assertion 4: Step 10a must explicitly prohibit closing the story when validation fails.

    When overall_verdict: FAIL and all tasks are closed, the orchestrator must
    NOT close the story. The instruction must be explicit to prevent the
    orchestrator from rationalizing that "tasks are done, story can close."
    """
    content = _read_skill()
    step_10a = _extract_step_10a(content)

    assert step_10a, "Expected to find Step 10a in SKILL.md but none was found."

    # Must contain an explicit "Do NOT close the story" instruction
    assert re.search(
        r"do not close the story"
        r"|do not close.*story"
        r"|must not close.*story"
        r"|story.*must not.*clos"
        r"|story.*do not.*clos",
        step_10a,
        re.IGNORECASE,
    ), (
        "Expected Step 10a to contain an explicit 'Do NOT close the story' instruction "
        "for the case where all tasks are closed but validation fails. Without this "
        "explicit prohibition, the orchestrator may rationalize closing the story "
        "because all tasks are done, even though the story's done definition is "
        "still failing. No such prohibition was found."
    )
