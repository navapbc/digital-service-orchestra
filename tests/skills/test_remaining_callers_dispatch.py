"""Tests for complexity evaluator dispatch in brainstorm, fix-bug, and debug-everything.

TDD spec for task w21-cw8j (RED → GREEN):
- brainstorm/SKILL.md Step 4a must dispatch via subagent_type 'dso:complexity-evaluator'
  instead of loading shared rubric content into a generic haiku task prompt.
- fix-bug/SKILL.md Step 4.5 must reference 'complexity-evaluator' (the agent definition file)
  instead of 'skills/shared/prompts/complexity-evaluator.md'. Due to Critical Rule 23
  (two-level nesting risk), fix-bug uses inline Read of the agent definition rather than
  sub-agent dispatch.
- debug-everything/SKILL.md must reference that fix-bug uses the named agent for post-
  investigation complexity evaluation.
- Context-specific routing logic must remain in each calling skill (not moved into the agent).
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BRAINSTORM_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "brainstorm" / "SKILL.md"
FIX_BUG_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"
DEBUG_EVERYTHING_MD = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "debug-everything" / "SKILL.md"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _read(path: pathlib.Path) -> str:
    return path.read_text()


def _extract_step4a_section(content: str) -> str:
    """Extract Step 4a section between its heading and the next heading."""
    pattern = re.compile(
        r"#### Step 4a:.*?(?=\n#### |\n### |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


def _extract_step45_section(content: str) -> str:
    """Extract Step 4.5 section between its heading and the next heading."""
    pattern = re.compile(
        r"### Step 4\.5:.*?(?=\n### |\n## |\Z)",
        re.DOTALL,
    )
    match = pattern.search(content)
    return match.group(0) if match else ""


# ---------------------------------------------------------------------------
# brainstorm/SKILL.md — Step 4a dispatch
# ---------------------------------------------------------------------------


def test_brainstorm_step4a_references_dso_complexity_evaluator() -> None:
    """Step 4a in brainstorm/SKILL.md must reference 'dso:complexity-evaluator' for dispatch."""
    content = _read(BRAINSTORM_MD)
    step4a = _extract_step4a_section(content)

    assert step4a, (
        "Expected to find a 'Step 4a:' section in brainstorm/SKILL.md but none was found. "
        "Check that the heading matches '#### Step 4a: ...'."
    )

    assert "dso:complexity-evaluator" in step4a, (
        "Expected Step 4a of brainstorm/SKILL.md to dispatch complexity evaluation via "
        "'dso:complexity-evaluator' (subagent_type), but it was not found. "
        "Update Step 4a to use subagent_type='dso:complexity-evaluator' instead of "
        "loading the prompt content from shared/prompts/complexity-evaluator.md."
    )


def test_brainstorm_step4a_does_not_load_shared_rubric_into_task_prompt() -> None:
    """Step 4a must NOT reference loading 'shared/prompts/complexity-evaluator.md' content into a task prompt."""
    content = _read(BRAINSTORM_MD)
    step4a = _extract_step4a_section(content)

    assert step4a, (
        "Expected to find a 'Step 4a:' section in brainstorm/SKILL.md but none was found. "
        "Check that the heading matches '#### Step 4a: ...'."
    )

    assert "shared/prompts/complexity-evaluator.md" not in step4a, (
        "Expected Step 4a of brainstorm/SKILL.md NOT to reference loading prompt content from "
        "'shared/prompts/complexity-evaluator.md'. "
        "Use subagent_type='dso:complexity-evaluator' for dispatch instead."
    )


def test_brainstorm_routing_table_remains_in_skill() -> None:
    """brainstorm/SKILL.md must still contain its context-specific routing table (TRIVIAL/MODERATE/COMPLEX)."""
    content = _read(BRAINSTORM_MD)

    assert "TRIVIAL" in content and "MODERATE" in content and "COMPLEX" in content, (
        "Expected brainstorm/SKILL.md to contain 'TRIVIAL', 'MODERATE', and 'COMPLEX' "
        "routing classification labels. Context-specific routing must remain in the calling "
        "skill, not be moved into the agent definition."
    )

    # The routing table must include brainstorm's specific MODERATE+scope_certainty logic
    assert re.search(
        r"MODERATE.*?scope_certainty|scope_certainty.*?MODERATE",
        content,
        re.DOTALL | re.IGNORECASE,
    ), (
        "Expected brainstorm/SKILL.md to contain the MODERATE + scope_certainty routing logic "
        "(e.g., MODERATE+High → preplanning --lightweight, MODERATE+Medium → preplanning --lightweight). "
        "This context-specific routing must remain in brainstorm/SKILL.md."
    )


# ---------------------------------------------------------------------------
# fix-bug/SKILL.md — Step 4.5 inline evaluation
# ---------------------------------------------------------------------------


def test_fix_bug_step45_references_complexity_evaluator() -> None:
    """Step 4.5 in fix-bug/SKILL.md must reference 'complexity-evaluator' for evaluation."""
    content = _read(FIX_BUG_MD)
    step45 = _extract_step45_section(content)

    assert step45, (
        "Expected to find a 'Step 4.5:' section in fix-bug/SKILL.md but none was found. "
        "Check that the heading matches '### Step 4.5: ...'."
    )

    assert "complexity-evaluator" in step45, (
        "Expected Step 4.5 of fix-bug/SKILL.md to reference 'complexity-evaluator' "
        "(the agent definition file) for complexity evaluation, but it was not found. "
        "Update Step 4.5 to Read from 'plugins/dso/agents/complexity-evaluator.md' "
        "instead of 'skills/shared/prompts/complexity-evaluator.md'."
    )


def test_fix_bug_step45_does_not_reference_shared_prompts_rubric() -> None:
    """Step 4.5 must NOT reference 'skills/shared/prompts/complexity-evaluator.md'."""
    content = _read(FIX_BUG_MD)
    step45 = _extract_step45_section(content)

    assert step45, (
        "Expected to find a 'Step 4.5:' section in fix-bug/SKILL.md but none was found. "
        "Check that the heading matches '### Step 4.5: ...'."
    )

    assert "skills/shared/prompts/complexity-evaluator.md" not in step45, (
        "Expected Step 4.5 of fix-bug/SKILL.md NOT to reference the old shared rubric path "
        "'skills/shared/prompts/complexity-evaluator.md'. "
        "Update to read from 'plugins/dso/agents/complexity-evaluator.md' instead."
    )


def test_fix_bug_routing_remains_in_skill() -> None:
    """fix-bug/SKILL.md must still contain TRIVIAL/MODERATE proceed and COMPLEX escalation routing."""
    content = _read(FIX_BUG_MD)

    assert "TRIVIAL" in content and "MODERATE" in content and "COMPLEX" in content, (
        "Expected fix-bug/SKILL.md to contain 'TRIVIAL', 'MODERATE', and 'COMPLEX' "
        "routing classification labels. Context-specific routing must remain in fix-bug/SKILL.md."
    )

    # fix-bug's routing: TRIVIAL/MODERATE proceed, COMPLEX escalates
    assert re.search(
        r"TRIVIAL or MODERATE|TRIVIAL.*?MODERATE.*?proceed|proceed.*?TRIVIAL.*?MODERATE",
        content,
        re.DOTALL | re.IGNORECASE,
    ), (
        "Expected fix-bug/SKILL.md to contain the 'TRIVIAL or MODERATE' proceed routing. "
        "Context-specific routing (TRIVIAL/MODERATE → proceed, COMPLEX → escalate) must "
        "remain in fix-bug/SKILL.md."
    )


# ---------------------------------------------------------------------------
# debug-everything/SKILL.md — references updated to reflect named agent
# ---------------------------------------------------------------------------


def test_debug_everything_references_complexity_evaluator_for_fix_bug() -> None:
    """debug-everything/SKILL.md must reference 'complexity-evaluator' or 'named agent' re: fix-bug evaluation."""
    content = _read(DEBUG_EVERYTHING_MD)

    assert re.search(r"complexity.evaluator|named agent", content, re.IGNORECASE), (
        "Expected debug-everything/SKILL.md to reference 'complexity-evaluator' or 'named agent' "
        "in the context of fix-bug's post-investigation complexity evaluation. "
        "Update the Tier 2+ note to reflect that fix-bug now reads the agent definition "
        "file (plugins/dso/agents/complexity-evaluator.md) for inline evaluation."
    )
