"""Tests for batch title display instruction in sprint/SKILL.md.

TDD spec for task w21-ncn7 (RED → GREEN):
- SKILL.md Phase 5 must contain a 'Display Batch Task List' instruction that:
  1. Appears within the Phase 5 section bounds
  2. Includes a concrete numbered-list example using the '1. [' format
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


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


def test_sprint_skill_contains_pre_launch_title_list() -> None:
    """Phase 5 of SKILL.md must contain 'Display Batch Task List' with a concrete example."""
    content = _read_skill()
    phase5 = _extract_phase5_section(content)

    assert phase5, (
        "Expected to find a 'Phase 5:' section in SKILL.md but none was found. "
        "Check that the Phase 5 heading matches '## Phase 5: ...'."
    )

    assert "Display Batch Task List" in phase5, (
        "Expected Phase 5 of SKILL.md to contain 'Display Batch Task List' instruction "
        "directing the orchestrator to print task titles before dispatching sub-agents. "
        "Add the instruction between the 'Claim Tasks' and 'Blackboard Write' sections."
    )

    assert "1. [" in phase5, (
        "Expected Phase 5 of SKILL.md to contain a concrete numbered-list example "
        "in the format '1. [dso-abc1] Fix authentication bug' to show orchestrators "
        "how to display batch task titles. Add '1. [' as part of the example."
    )
