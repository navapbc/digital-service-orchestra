"""Test that end-session/SKILL.md has bug ticket creation in Step 2.85 (pre-commit).

TDD spec for task lockpick-doc-to-logic-ewz1:
1. Step 2.85 heading exists
2. Bug ticket creation text ('tk create' for bug tickets) appears in Step 2.85 section
3. Step 2.85 appears before Step 3 commit section
4. Step 6 no longer contains the bug ticket creation block
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "end-session" / "SKILL.md"


def _get_line_number(content: str, pattern: str) -> int:
    """Return the line number (1-based) of the first line matching pattern, or -1."""
    for i, line in enumerate(content.splitlines(), start=1):
        if re.search(pattern, line):
            return i
    return -1


def _extract_section(content: str, start_pattern: str, end_pattern: str) -> str:
    """Extract text between two heading patterns (exclusive of end heading)."""
    lines = content.splitlines()
    in_section = False
    result = []
    for line in lines:
        if re.search(start_pattern, line):
            in_section = True
        elif in_section and re.search(end_pattern, line):
            break
        if in_section:
            result.append(line)
    return "\n".join(result)


def test_step_2_85_heading_exists() -> None:
    """Step 2.85 heading must exist in the skill file."""
    content = SKILL_MD.read_text()
    assert re.search(r"###\s+2\.85\.", content), (
        "end-session/SKILL.md is missing a Step 2.85 heading (e.g., '### 2.85. ...'). "
        "Bug ticket creation from learnings must be a pre-commit step."
    )


def test_step_2_85_contains_bug_ticket_creation() -> None:
    """Step 2.85 must contain a bug ticket creation instruction."""
    content = SKILL_MD.read_text()
    # Extract the Step 2.85 section (from 2.85 heading to next heading)
    section = _extract_section(content, r"###\s+2\.85\.", r"###\s+[23]\.")
    assert section, "Step 2.85 section not found in SKILL.md."
    assert re.search(r"ticket create bug|tk create.*-t bug|-t bug", section), (
        "Step 2.85 does not contain bug ticket creation instruction. "
        "Accepted forms: 'ticket create bug' (positional) or 'tk create ... -t bug'. "
        "Bug tickets from learnings must be created in Step 2.85."
    )


def test_step_2_85_before_step_3_commit() -> None:
    """Step 2.85 must appear before Step 3 (Commit) in the file."""
    content = SKILL_MD.read_text()
    pos_2_85 = _get_line_number(content, r"###\s+2\.85\.")
    pos_3 = _get_line_number(content, r"###\s+3\.\s+Commit")
    assert pos_2_85 != -1, "Step 2.85 heading not found."
    assert pos_3 != -1, "Step 3 Commit heading not found."
    assert pos_2_85 < pos_3, (
        f"Step 2.85 (line {pos_2_85}) must appear before Step 3 Commit (line {pos_3})."
    )


def test_step_6_no_longer_contains_bug_ticket_creation() -> None:
    """Step 6 must not contain the bug ticket creation block ('tk create -t bug')."""
    content = SKILL_MD.read_text()
    # Extract Step 6 section (from ### 6. to ### 7.)
    section = _extract_section(content, r"###\s+6\.", r"###\s+7\.")
    assert section, "Step 6 heading not found in SKILL.md."
    assert not re.search(r"tk create.*-t bug|-t bug", section), (
        "Step 6 still contains bug ticket creation ('tk create' with '-t bug'). "
        "Bug ticket creation must be moved to Step 2.85 (pre-commit)."
    )
