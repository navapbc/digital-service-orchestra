"""Test that end-session/SKILL.md Step 6 displays stored learnings from Step 2.8.

TDD spec for task lockpick-doc-to-logic-a38h:
1. Step 6 does not contain 'scan git diff and conversation for signal'
2. Step 6 Technical Learnings section references 'Step 2.8' or 'generated earlier' or 'stored learnings'
3. Step 6 preserves Discoveries/Design decisions/Gotchas bullet structure (for display)
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "end-session" / "SKILL.md"


def _get_step_6_block(content: str) -> str:
    """Extract the content of Step 6 (between ### 6. and ### 7.)."""
    lines = content.splitlines()
    in_step_6 = False
    step_6_lines: list[str] = []
    for line in lines:
        if re.search(r"###\s+6\.", line):
            in_step_6 = True
        elif re.search(r"###\s+7\.", line) and in_step_6:
            break
        if in_step_6:
            step_6_lines.append(line)
    return "\n".join(step_6_lines)


def test_step_6_does_not_scan_git_diff() -> None:
    """Step 6 must not contain 'scan git diff and conversation for signal'."""
    content = SKILL_MD.read_text()
    step_6 = _get_step_6_block(content)
    assert "scan git diff and conversation for signal" not in step_6, (
        "Step 6 still contains 'scan git diff and conversation for signal'. "
        "Learnings are now generated in Step 2.8 and should only be displayed in Step 6."
    )


def test_step_6_technical_learnings_references_step_2_8() -> None:
    """Step 6 Technical Learnings section must reference stored learnings from Step 2.8."""
    content = SKILL_MD.read_text()
    step_6 = _get_step_6_block(content)
    assert step_6, "Step 6 content not found in SKILL.md."
    has_reference = re.search(r"Step 2\.8|generated earlier|stored learnings", step_6)
    assert has_reference, (
        "Step 6 Technical Learnings does not reference stored learnings from Step 2.8. "
        "It should mention 'Step 2.8', 'generated earlier', or 'stored learnings'."
    )


def test_step_6_preserves_discoveries_design_gotchas_structure() -> None:
    """Step 6 must preserve Discoveries/Design decisions/Gotchas structure for display."""
    content = SKILL_MD.read_text()
    step_6 = _get_step_6_block(content)
    assert step_6, "Step 6 content not found in SKILL.md."
    has_discoveries = "Discoveries" in step_6
    has_design_decisions = "Design decisions" in step_6
    has_gotchas = "Gotchas" in step_6
    assert has_discoveries and has_design_decisions and has_gotchas, (
        f"Step 6 is missing required display structure. "
        f"Discoveries: {has_discoveries}, Design decisions: {has_design_decisions}, "
        f"Gotchas: {has_gotchas}. "
        "Step 6 must show the Discoveries/Design decisions/Gotchas bullets from LEARNINGS_FROM_2_8."
    )
