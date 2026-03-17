"""Test that end-session/SKILL.md has Step 4.75 final worktree verification.

TDD spec for task lockpick-doc-to-logic-65d3:
1. Step 4.75 heading exists
2. Step 4.75 contains 'merge-base --is-ancestor' (is_merged check)
3. Step 4.75 contains 'status --porcelain' (is_clean check)
4. Step 4.75 references claude-safe or _offer_worktree_cleanup to signal sync intent
5. Step 4.75 appears before Step 6 (Session Complete)
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "skills" / "end-session" / "SKILL.md"


def _get_section_content(content: str, start_pattern: str, end_pattern: str) -> str:
    """Return the text between the first line matching start_pattern and end_pattern."""
    lines = content.splitlines()
    start = -1
    end = -1
    for i, line in enumerate(lines):
        if start == -1 and re.search(start_pattern, line):
            start = i
        elif start != -1 and re.search(end_pattern, line):
            end = i
            break
    if start == -1:
        return ""
    if end == -1:
        return "\n".join(lines[start:])
    return "\n".join(lines[start:end])


def _get_line_number(content: str, pattern: str) -> int:
    """Return the 1-based line number of the first match, or -1."""
    for i, line in enumerate(content.splitlines(), start=1):
        if re.search(pattern, line):
            return i
    return -1


def test_step_4_75_heading_exists() -> None:
    """Step 4.75 heading must exist in the skill file."""
    content = SKILL_MD.read_text()
    assert re.search(r"###\s+4\.75\.", content), (
        "end-session/SKILL.md is missing a Step 4.75 heading (e.g., '### 4.75. ...'). "
        "Final worktree verification must be added as Step 4.75."
    )


def test_step_4_75_contains_is_merged_check() -> None:
    """Step 4.75 must contain the is_merged check using merge-base --is-ancestor."""
    content = SKILL_MD.read_text()
    section = _get_section_content(content, r"###\s+4\.75\.", r"###\s+5\.")
    assert section, (
        "Step 4.75 section not found (or Step 5 heading not found after it)."
    )
    assert "merge-base --is-ancestor" in section, (
        "Step 4.75 must include the is_merged check: "
        "'git merge-base --is-ancestor \"$BRANCH\" main'. "
        "This mirrors the exact logic in claude-safe's _offer_worktree_cleanup."
    )


def test_step_4_75_contains_is_clean_check() -> None:
    """Step 4.75 must contain the is_clean check using status --porcelain."""
    content = SKILL_MD.read_text()
    section = _get_section_content(content, r"###\s+4\.75\.", r"###\s+5\.")
    assert section, (
        "Step 4.75 section not found (or Step 5 heading not found after it)."
    )
    assert "status --porcelain" in section, (
        "Step 4.75 must include the is_clean check: "
        "'git status --porcelain' (empty output = clean). "
        "This mirrors the exact logic in claude-safe's _offer_worktree_cleanup."
    )


def test_step_4_75_references_claude_safe() -> None:
    """Step 4.75 must reference claude-safe or _offer_worktree_cleanup to signal sync intent."""
    content = SKILL_MD.read_text()
    section = _get_section_content(content, r"###\s+4\.75\.", r"###\s+5\.")
    assert section, (
        "Step 4.75 section not found (or Step 5 heading not found after it)."
    )
    assert re.search(r"claude-safe|_offer_worktree_cleanup", section), (
        "Step 4.75 must reference 'claude-safe' or '_offer_worktree_cleanup' "
        "as the canonical source of the is_merged+is_clean logic, "
        "so that the skill and the script stay in sync."
    )


def test_step_4_75_before_step_6() -> None:
    """Step 4.75 must appear before Step 6 (Session Complete) in the file."""
    content = SKILL_MD.read_text()
    pos_4_75 = _get_line_number(content, r"###\s+4\.75\.")
    pos_6 = _get_line_number(content, r"###\s+6\.")
    assert pos_4_75 != -1, "Step 4.75 heading not found."
    assert pos_6 != -1, "Step 6 heading not found."
    assert pos_4_75 < pos_6, (
        f"Step 4.75 (line {pos_4_75}) must appear before Step 6 (line {pos_6})."
    )
