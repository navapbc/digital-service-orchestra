"""Tests for complexity evaluator dispatch in sprint/SKILL.md.

TDD spec for task dso-fg3m (RED → GREEN — GREEN achieved by dso-3650):
- SKILL.md Step 2b (Epic Complexity Evaluation) must dispatch via
  subagent_type 'dso:complexity-evaluator' instead of loading a local prompt file.
- SKILL.md Step 1: Identify Stories must also dispatch via
  subagent_type 'dso:complexity-evaluator' instead of loading a local prompt file.
- Context-specific routing logic (MODERATE->COMPLEX) must remain in sprint SKILL.md.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def _extract_step2b_section(content: str) -> str:
    """Extract Step 2b section between the Step 2b heading and the next heading."""
    pattern = re.compile(
        r"#### Step 2b:.*?(?=\n#### |\n### |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    if match is None:
        return ""
    return match.group(0)


def _extract_identify_stories_section(content: str) -> str:
    """Extract 'Step 1: Identify Stories' section up to the next heading."""
    pattern = re.compile(
        r"#### Step 1: Identify Stories.*?(?=\n#### |\n### |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    if match is None:
        return ""
    return match.group(0)


def test_step2b_dispatches_via_complexity_evaluator_agent() -> None:
    """Step 2b must reference 'dso:complexity-evaluator' for epic classification dispatch."""
    content = _read_skill()
    step2b = _extract_step2b_section(content)

    assert step2b, (
        "Expected to find a 'Step 2b:' section in SKILL.md but none was found. "
        "Check that the heading matches '#### Step 2b: ...'."
    )

    assert "dso:complexity-evaluator" in step2b, (
        "Expected Step 2b of SKILL.md to dispatch epic complexity evaluation via "
        "'dso:complexity-evaluator' (subagent_type), but it was not found. "
        "Update Step 2b to use subagent_type='dso:complexity-evaluator' instead of "
        "loading the prompt from sprint/prompts/epic-complexity-evaluator.md."
    )


def test_step2b_does_not_load_local_epic_complexity_evaluator_prompt() -> None:
    """Step 2b must NOT reference loading from sprint/prompts/epic-complexity-evaluator.md."""
    content = _read_skill()
    step2b = _extract_step2b_section(content)

    assert step2b, (
        "Expected to find a 'Step 2b:' section in SKILL.md but none was found. "
        "Check that the heading matches '#### Step 2b: ...'."
    )

    assert "epic-complexity-evaluator.md" not in step2b, (
        "Expected Step 2b of SKILL.md NOT to reference loading the prompt from "
        "'sprint/prompts/epic-complexity-evaluator.md'. "
        "The epic complexity evaluator should be dispatched as a dedicated agent "
        "via subagent_type='dso:complexity-evaluator', not by reading a local prompt file."
    )


def test_identify_stories_dispatches_via_complexity_evaluator_agent() -> None:
    """Step 1: Identify Stories must reference 'dso:complexity-evaluator' for story classification."""
    content = _read_skill()
    identify = _extract_identify_stories_section(content)

    assert identify, (
        "Expected to find a 'Step 1: Identify Stories' section in SKILL.md but none was found. "
        "Check that the heading matches '#### Step 1: Identify Stories ...'."
    )

    assert "dso:complexity-evaluator" in identify, (
        "Expected 'Step 1: Identify Stories' of SKILL.md to dispatch story complexity evaluation "
        "via 'dso:complexity-evaluator' (subagent_type), but it was not found. "
        "Update Step 1 to use subagent_type='dso:complexity-evaluator' instead of "
        "loading the prompt from sprint/prompts/complexity-evaluator.md."
    )


def test_identify_stories_does_not_load_local_complexity_evaluator_prompt() -> None:
    """Step 1: Identify Stories must NOT reference loading from sprint/prompts/complexity-evaluator.md."""
    content = _read_skill()
    identify = _extract_identify_stories_section(content)

    assert identify, (
        "Expected to find a 'Step 1: Identify Stories' section in SKILL.md but none was found. "
        "Check that the heading matches '#### Step 1: Identify Stories ...'."
    )

    assert "prompts/complexity-evaluator.md" not in identify, (
        "Expected 'Step 1: Identify Stories' of SKILL.md NOT to reference loading the prompt "
        "from 'sprint/prompts/complexity-evaluator.md'. "
        "The story complexity evaluator should be dispatched as a dedicated agent "
        "via subagent_type='dso:complexity-evaluator', not by reading a local prompt file."
    )


def test_moderate_to_complex_routing_remains_in_skill() -> None:
    """The MODERATE->COMPLEX routing text must still exist in SKILL.md (routing stays in sprint)."""
    content = _read_skill()

    assert "MODERATE" in content and "COMPLEX" in content, (
        "Expected SKILL.md to contain both 'MODERATE' and 'COMPLEX' routing classifications. "
        "Context-specific routing (e.g., MODERATE->COMPLEX escalation) must remain in "
        "sprint SKILL.md even after complexity evaluation is delegated to a sub-agent."
    )

    # More targeted: the routing table with MODERATE->COMPLEX path must exist
    assert re.search(r"MODERATE.*?COMPLEX|Treat as COMPLEX", content, re.DOTALL), (
        "Expected SKILL.md to contain the MODERATE->COMPLEX routing rule "
        "(e.g., 'Treat as COMPLEX' or a routing table row with MODERATE → COMPLEX). "
        "This context-specific routing logic must remain in sprint SKILL.md."
    )
