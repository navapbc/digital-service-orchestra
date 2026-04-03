"""Tests for implementation-plan skill eval RED task creation.

Bug 9f5b-7f48: implementation-plan skill does not create RED test tasks
for skill/prompt file changes — it blanket-exempts them as static assets.

These tests verify that:
1. The exemption criteria contain a carve-out for skill/prompt files with eval configs
2. An Eval RED Task section exists defining the task template
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
IMPL_PLAN_SKILL_MD = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"
)


def _read_skill() -> str:
    return IMPL_PLAN_SKILL_MD.read_text()


def test_exemption_criteria_has_skill_file_carveout() -> None:
    """The Unit Test Exemption Criteria must not blanket-exempt skill/prompt files.

    Bug 9f5b-7f48: SKILL.md files are Markdown but are behaviorally testable
    via promptfoo evals. The exemption criteria must contain an exception for
    files with a sibling evals/promptfooconfig.yaml.
    """
    content = _read_skill()

    # Extract the section from "Unit Test Exemption Criteria" to "Integration Test"
    pattern = re.compile(
        r"#### Unit Test Exemption Criteria.*?(?=#### Integration Test|#### Eval RED|\Z)",
        re.DOTALL,
    )
    section = pattern.search(content)
    assert section, "Expected 'Unit Test Exemption Criteria' section in SKILL.md."

    section_text = section.group(0)

    # Must mention skill files, SKILL.md, or eval configs as an exception
    has_carveout = re.search(
        r"SKILL\.md.*(?:eval|promptfoo|not.*static|exception|override)"
        r"|skill.*prompt.*(?:eval|not.*exempt|not.*static)"
        r"|promptfooconfig\.yaml.*(?:not.*apply|exception|override|not.*static)",
        section_text,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_carveout, (
        "Expected the Unit Test Exemption Criteria to contain a carve-out for "
        "SKILL.md and prompt files that have a sibling evals/promptfooconfig.yaml. "
        "Currently, criterion 3 matches SKILL.md as 'Markdown documentation' with "
        "no exception for eval-covered files."
    )


def test_tdd_reviewer_has_skill_file_exception() -> None:
    """The TDD plan reviewer criterion 3 must have an exception for eval-covered skill files."""
    tdd_md = (
        REPO_ROOT
        / "plugins"
        / "dso"
        / "skills"
        / "implementation-plan"
        / "docs"
        / "reviewers"
        / "plan"
        / "tdd.md"
    )
    content = tdd_md.read_text()

    has_exception = re.search(
        r"SKILL\.md.*(?:NOT static|not.*static|exception|eval|promptfoo)"
        r"|prompt files.*(?:NOT static|not.*static|eval|run-skill-evals)",
        content,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_exception, (
        "Expected tdd.md criterion 3 to contain an exception for SKILL.md and "
        "prompt files with eval configs. Without this, the plan reviewer will "
        "accept blanket criterion 3 exemptions for eval-covered skill files."
    )


def test_eval_red_task_section_exists() -> None:
    """An Eval RED Task section must exist for skill/prompt file changes.

    Bug 9f5b-7f48: The TDD Task Structure must define what a RED eval task
    looks like for skill files, using run-skill-evals.sh as the test runner.
    """
    content = _read_skill()

    has_eval_task_section = re.search(
        r"Eval RED Task.*(?:skill|prompt|SKILL\.md)",
        content,
        re.IGNORECASE | re.DOTALL,
    )
    assert has_eval_task_section, (
        "Expected an 'Eval RED Task' section in the implementation-plan SKILL.md "
        "that defines the task template for skill/prompt file changes. This section "
        "should reference run-skill-evals.sh as the test runner for behavioral "
        "assertions on skill files."
    )
