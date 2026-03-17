"""Test that end-session/SKILL.md has learnings extraction in Step 2.8 (pre-commit).

TDD spec for task lockpick-doc-to-logic-rwy2:
1. Step 2.8 heading exists
2. Step 2.8 position < Step 3 commit position
3. Step 6 no longer contains 'scan git diff and conversation for signal'
4. Step 6 references learnings generated in Step 2.8
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "end-session" / "SKILL.md"


def _get_line_number(content: str, pattern: str) -> int:
    """Return the line number (1-based) of the first line matching pattern, or -1."""
    for i, line in enumerate(content.splitlines(), start=1):
        if re.search(pattern, line):
            return i
    return -1


def test_step_2_8_heading_exists() -> None:
    """Step 2.8 heading must exist in the skill file."""
    content = SKILL_MD.read_text()
    assert re.search(r"###\s+2\.8\.", content), (
        "end-session/SKILL.md is missing a Step 2.8 heading (e.g., '### 2.8. ...'). "
        "Technical learnings extraction must be moved to a pre-commit step."
    )


def test_step_2_8_before_step_3_commit() -> None:
    """Step 2.8 must appear before Step 3 (Commit) in the file."""
    content = SKILL_MD.read_text()
    pos_2_8 = _get_line_number(content, r"###\s+2\.8\.")
    pos_3 = _get_line_number(content, r"###\s+3\.\s+Commit")
    assert pos_2_8 != -1, "Step 2.8 heading not found."
    assert pos_3 != -1, "Step 3 Commit heading not found."
    assert pos_2_8 < pos_3, (
        f"Step 2.8 (line {pos_2_8}) must appear before Step 3 Commit (line {pos_3})."
    )


def test_step_6_no_longer_scans_git_diff() -> None:
    """Step 6 must not contain 'scan git diff and conversation for signal'."""
    content = SKILL_MD.read_text()
    assert "scan git diff and conversation for signal" not in content, (
        "end-session/SKILL.md Step 6 still contains the old 'scan git diff and conversation "
        "for signal' instruction. This must be removed — learnings are now generated in Step 2.8."
    )


def test_step_6_references_step_2_8_learnings() -> None:
    """Step 6 must reference the stored learnings from Step 2.8."""
    content = SKILL_MD.read_text()
    lines = content.splitlines()

    # Find Step 6 heading
    step_6_line = -1
    for i, line in enumerate(lines):
        if re.search(r"###\s+6\.", line):
            step_6_line = i
            break

    assert step_6_line != -1, "Step 6 heading not found in SKILL.md."

    # Check the next 20 lines after Step 6 heading for a reference to Step 2.8 learnings
    step_6_block = "\n".join(lines[step_6_line : step_6_line + 20])
    has_reference = re.search(
        r"Step 2\.8|generated earlier|stored learnings", step_6_block
    )
    assert has_reference, (
        "Step 6 does not reference learnings from Step 2.8. "
        "It should mention 'Step 2.8', 'generated earlier', or 'stored learnings' "
        "within its first 20 lines."
    )
