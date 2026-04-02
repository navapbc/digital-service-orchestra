"""Tests for ast-grep guidance in sprint/SKILL.md Phase 3 (Batch Preparation).

TDD spec for story 0368-4d68:
- SKILL.md Phase 3 (Batch Preparation) must contain ast-grep (sg) guidance for
  dependency-aware overlap analysis, with:
  1. A `command -v sg` availability guard
  2. A Grep fallback instruction when sg is unavailable
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def _extract_phase3_section(content: str) -> str:
    """Extract Phase 3 content between the Phase 3 heading and the next Phase heading."""
    phase3_pattern = re.compile(
        r"## Phase 3:.*?(?=\n## Phase \d+:|\Z)",
        re.DOTALL,
    )
    match = phase3_pattern.search(content)
    if match is None:
        return ""
    return match.group(0)


def test_phase3_contains_ast_grep_availability_guard() -> None:
    """Phase 3 of SKILL.md must contain a 'command -v sg' guard for ast-grep availability."""
    content = _read_skill()
    phase3 = _extract_phase3_section(content)

    assert phase3, (
        "Expected to find a 'Phase 3:' section in SKILL.md but none was found. "
        "Check that the Phase 3 heading matches '## Phase 3: ...'."
    )

    assert "command -v sg" in phase3, (
        "Expected Phase 3 of SKILL.md to contain 'command -v sg' for checking whether "
        "ast-grep is available before using it for dependency-aware overlap analysis. "
        "Add the canonical guard pattern to Phase 3 Step 4 (Batch Composition)."
    )


def test_phase3_contains_grep_fallback() -> None:
    """Phase 3 of SKILL.md must describe a Grep fallback when sg is unavailable."""
    content = _read_skill()
    phase3 = _extract_phase3_section(content)

    assert phase3, (
        "Expected to find a 'Phase 3:' section in SKILL.md but none was found. "
        "Check that the Phase 3 heading matches '## Phase 3: ...'."
    )

    # Require a specific fallback phrase — checking 'grep' alone would trivially pass
    # because 'ast-grep' contains 'grep'. Look for a genuine fallback instruction.
    has_grep_fallback = any(
        phrase in phase3
        for phrase in (
            "Fall back to Grep",
            "fall back to Grep",
            "fallback to Grep",
            "Grep tool",
            "grep -r",
            "Grep fallback",
        )
    )
    assert has_grep_fallback, (
        "Expected Phase 3 of SKILL.md to mention a Grep fallback when sg (ast-grep) "
        "is unavailable (e.g. 'Fall back to Grep', 'Grep tool', or 'grep -r'). "
        "Add a fallback instruction in the ast-grep guidance block within Phase 3 Step 4."
    )
