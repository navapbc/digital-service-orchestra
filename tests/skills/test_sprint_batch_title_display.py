"""Tests for batch title display instruction in sprint/SKILL.md.

TDD spec for task w21-ncn7 (RED → GREEN):
- SKILL.md Phase 4 (Sub-Agent Launch) must contain a 'Display Batch Task List' instruction that:
  1. Appears within the Phase 4 section bounds
  2. Includes a concrete numbered-list example using the '1. [' format
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def _extract_phase4_section(content: str) -> str:
    """Extract Phase 4 content between the Phase 4 heading and the next Phase heading."""
    phase4_pattern = re.compile(
        r"## Phase 4:.*?(?=\n## Phase \d+:|\Z)",
        re.DOTALL,
    )
    match = phase4_pattern.search(content)
    if match is None:
        return ""
    return match.group(0)


def test_sprint_skill_contains_pre_launch_title_list() -> None:
    """Phase 4 of SKILL.md must contain 'Display Batch Task List' with a concrete example."""
    content = _read_skill()
    phase4 = _extract_phase4_section(content)

    assert phase4, (
        "Expected to find a 'Phase 4:' section in SKILL.md but none was found. "
        "Check that the Phase 4 heading matches '## Phase 4: ...'."
    )

    assert "Display Batch Task List" in phase4, (
        "Expected Phase 4 of SKILL.md to contain 'Display Batch Task List' instruction "
        "directing the orchestrator to print task titles before dispatching sub-agents. "
        "Add the instruction between the 'Claim Tasks' and 'Blackboard Write' sections."
    )

    assert "1. [" in phase4, (
        "Expected Phase 4 of SKILL.md to contain a concrete numbered-list example "
        "in the format '1. [dso-abc1] Fix authentication bug' to show orchestrators "
        "how to display batch task titles. Add '1. [' as part of the example."
    )


def _extract_phase5_section(content: str) -> str:
    """Extract Phase 5 content between the Phase 5 heading and the next Phase heading."""
    phase5_pattern = re.compile(
        r"## Phase 5:.*?(?=\n## Phase \d+:|\Z)",
        re.DOTALL,
    )
    match = phase5_pattern.search(content)
    if match is None:
        return ""
    return match.group(0)


def test_sprint_skill_contains_completion_summary_titles() -> None:
    """Phase 5 of SKILL.md must contain 'Batch Completion Summary' with pass/fail example."""
    content = _read_skill()
    phase5 = _extract_phase5_section(content)

    assert phase5, (
        "Expected to find a 'Phase 5:' section in SKILL.md but none was found. "
        "Check that the Phase 5 heading matches '## Phase 5: ...'."
    )

    assert "Batch Completion Summary" in phase5, (
        "Expected Phase 5 of SKILL.md to contain 'Batch Completion Summary' instruction "
        "directing the orchestrator to print a completion summary after all sub-agents "
        "are verified. Add the instruction after 'Step 2: Acceptance Criteria Validation'."
    )

    assert "pass" in phase5, (
        "Expected Phase 5 of SKILL.md to contain a concrete example showing 'pass' "
        "outcome in the completion summary format. Add a pass/fail example such as "
        "'✓ [dso-abc1] Task title (pass)'."
    )

    assert "fail" in phase5, (
        "Expected Phase 5 of SKILL.md to contain a concrete example showing 'fail' "
        "outcome in the completion summary format. Add a pass/fail example such as "
        "'✗ [dso-abc2] Other task (fail — reverted to open)'."
    )
