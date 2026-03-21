"""Structural validation tests for complexity-evaluator and conflict-analyzer agent definitions.

SC4 smoke test (story w21-1bvu): verifies that all 5 callers can produce schema-valid output
by confirming the agent definitions contain the correct output schemas, and that each caller
skill file references the correct agent.

This is a structural validation test — it validates the agent definitions contain the correct
schemas, not that live dispatch produces correct output (live dispatch requires the Claude
Code runtime which tests cannot simulate).

Callers under test:
  1. Sprint epic evaluator  — sprint/SKILL.md Step 2b   → dso:complexity-evaluator (tier_schema=SIMPLE)
  2. Sprint story evaluator — sprint/SKILL.md Step 1    → dso:complexity-evaluator (tier_schema=TRIVIAL)
  3. Brainstorm             — brainstorm/SKILL.md Step 4a → dso:complexity-evaluator (subagent_type)
  4. Fix-bug                — fix-bug/SKILL.md Step 4.5  → complexity-evaluator (inline Read of agent def)
  5. Resolve-conflicts      — resolve-conflicts/SKILL.md Step 2 → dso:conflict-analyzer (subagent_type)

Note: Agent file existence and output schema field validation are covered by
test_complexity_evaluator_agent.py and test_conflict_analyzer_agent.py respectively.
This file focuses exclusively on verifying that each caller skill correctly references
the appropriate agent.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# Caller skill files
SPRINT_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"
BRAINSTORM_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "brainstorm" / "SKILL.md"
FIX_BUG_SKILL = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"
RESOLVE_CONFLICTS_SKILL = (
    REPO_ROOT / "plugins" / "dso" / "skills" / "resolve-conflicts" / "SKILL.md"
)


def _read(path: pathlib.Path) -> str:
    assert path.exists(), f"Required file missing: {path}"
    return path.read_text()


# ──────────────────────────────────────────────────────────────────────────────
# SECTION 3: Caller skill file → correct agent references
# ──────────────────────────────────────────────────────────────────────────────


def test_caller_1_sprint_epic_evaluator_references_complexity_evaluator() -> None:
    """Sprint epic evaluator (Step 2b) must dispatch dso:complexity-evaluator with tier_schema=SIMPLE."""
    content = _read(SPRINT_SKILL)
    # Extract Step 2b section
    step2b_match = re.search(
        r"#### Step 2b:.*?(?=\n#### |\n### |\Z)",
        content,
        re.DOTALL,
    )
    assert step2b_match, (
        "sprint/SKILL.md must contain a '#### Step 2b:' section for epic complexity evaluation."
    )
    step2b = step2b_match.group(0)
    assert "dso:complexity-evaluator" in step2b, (
        "sprint/SKILL.md Step 2b must dispatch via 'dso:complexity-evaluator' subagent_type."
    )
    assert "SIMPLE" in step2b, (
        "sprint/SKILL.md Step 2b must pass tier_schema=SIMPLE so the agent outputs "
        "SIMPLE/MODERATE/COMPLEX vocabulary for epic evaluation."
    )


def test_caller_2_sprint_story_evaluator_references_complexity_evaluator() -> None:
    """Sprint story evaluator (Step 1: Identify Stories) must dispatch dso:complexity-evaluator with tier_schema=TRIVIAL."""
    content = _read(SPRINT_SKILL)
    # Extract the Identify Stories section
    identify_match = re.search(
        r"#### Step 1: Identify Stories.*?(?=\n#### |\n### |\Z)",
        content,
        re.DOTALL,
    )
    assert identify_match, (
        "sprint/SKILL.md must contain a '#### Step 1: Identify Stories' section."
    )
    identify = identify_match.group(0)
    assert "dso:complexity-evaluator" in identify, (
        "sprint/SKILL.md Step 1 (Identify Stories) must dispatch via 'dso:complexity-evaluator' "
        "subagent_type for story classification."
    )
    assert "TRIVIAL" in identify, (
        "sprint/SKILL.md Step 1 must pass tier_schema=TRIVIAL so the agent outputs "
        "TRIVIAL/MODERATE/COMPLEX vocabulary for story evaluation."
    )


def test_caller_3_brainstorm_references_complexity_evaluator() -> None:
    """brainstorm/SKILL.md Step 4a must dispatch dso:complexity-evaluator via subagent_type."""
    content = _read(BRAINSTORM_SKILL)
    step4a_match = re.search(
        r"#### Step 4a:.*?(?=\n#### |\n### |\Z)",
        content,
        re.DOTALL,
    )
    assert step4a_match, (
        "brainstorm/SKILL.md must contain a '#### Step 4a:' section for complexity evaluator dispatch."
    )
    step4a = step4a_match.group(0)
    assert "dso:complexity-evaluator" in step4a, (
        "brainstorm/SKILL.md Step 4a must dispatch via 'dso:complexity-evaluator' subagent_type."
    )
    assert "subagent_type" in step4a, (
        "brainstorm/SKILL.md Step 4a must use 'subagent_type' dispatch for the complexity evaluator."
    )


def test_caller_4_fix_bug_reads_complexity_evaluator_agent_def() -> None:
    """fix-bug/SKILL.md Step 4.5 must reference 'plugins/dso/agents/complexity-evaluator.md' (inline Read)."""
    content = _read(FIX_BUG_SKILL)
    step45_match = re.search(
        r"### Step 4\.5:.*?(?=\n### |\n## |\Z)",
        content,
        re.DOTALL,
    )
    assert step45_match, (
        "fix-bug/SKILL.md must contain a '### Step 4.5:' section for complexity evaluation."
    )
    step45 = step45_match.group(0)
    assert "complexity-evaluator" in step45, (
        "fix-bug/SKILL.md Step 4.5 must reference 'complexity-evaluator' (the agent definition). "
        "Due to Critical Rule 23 (nested dispatch risk), fix-bug reads the agent definition "
        "inline rather than dispatching a sub-agent."
    )
    # Must reference the agent def path (agents/), not the old shared prompt path
    assert (
        "agents/complexity-evaluator" in step45
        or "plugins/dso/agents/complexity-evaluator" in step45
    ), (
        "fix-bug/SKILL.md Step 4.5 must reference the agent definition at "
        "'plugins/dso/agents/complexity-evaluator.md', not the old shared prompt path."
    )


def test_caller_5_resolve_conflicts_references_conflict_analyzer() -> None:
    """resolve-conflicts/SKILL.md Step 2 must dispatch dso:conflict-analyzer via subagent_type."""
    content = _read(RESOLVE_CONFLICTS_SKILL)
    # Find Step 2 section
    step2_match = re.search(
        r"### 2\. Analyze Conflicts.*?(?=\n### |\Z)",
        content,
        re.DOTALL,
    )
    assert step2_match, (
        "resolve-conflicts/SKILL.md must contain a '### 2. Analyze Conflicts' section."
    )
    step2 = step2_match.group(0)
    assert "dso:conflict-analyzer" in step2, (
        "resolve-conflicts/SKILL.md Step 2 must dispatch via 'dso:conflict-analyzer' subagent_type."
    )
    assert "subagent_type" in step2, (
        "resolve-conflicts/SKILL.md Step 2 must use 'subagent_type' dispatch for conflict analysis."
    )
