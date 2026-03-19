"""Test that end-session Step 4.75 handles dirty worktree after successful merge.

Bug w21-v1vi: /dso:end-session completed but worktree was not auto-removed because
uncommitted changes (debug artifacts) remained. Step 4.75 must include explicit
guidance for discarding uncommitted changes after a successful merge, giving the
user a choice before proceeding.

TDD RED: This test fails because Step 4.75 does not mention discarding changes
or git checkout/restore as a resolution for dirty worktrees post-merge.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "end-session" / "SKILL.md"


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


def test_step_4_75_offers_discard_for_post_merge_dirty_files() -> None:
    """Step 4.75 must offer to discard uncommitted changes after successful merge.

    When is_merged passes but is_clean fails, the dirty files are either already
    merged or are debug artifacts. The skill must explicitly offer discarding them
    (with user confirmation) as a resolution path.
    """
    content = SKILL_MD.read_text()
    section = _get_section_content(content, r"###\s+4\.75\.", r"###\s+5\.")
    assert section, "Step 4.75 section not found."

    # Must mention discarding/restoring changes as a resolution
    has_discard = re.search(
        r"discard|git\s+(checkout|restore)\s+\.|reset.*changes",
        section,
        re.IGNORECASE,
    )
    assert has_discard, (
        "Step 4.75 must include guidance for discarding uncommitted changes "
        "after a successful merge (e.g., 'git checkout .' or 'git restore .'). "
        "Bug w21-v1vi: dirty worktree left orphaned because end-session had no "
        "discard path for post-merge artifacts."
    )


def test_step_4_75_requires_user_confirmation_before_discard() -> None:
    """Discarding changes must require user confirmation — not be automatic.

    Per the ticket: 'User gets explicit choice to discard or commit remaining changes.'
    """
    content = SKILL_MD.read_text()
    section = _get_section_content(content, r"###\s+4\.75\.", r"###\s+5\.")
    assert section, "Step 4.75 section not found."

    # Must mention asking/confirming with user before discarding
    has_confirmation = re.search(
        r"ask.*user|user.*approv|confirm.*discard|user.*confirm|offer.*discard",
        section,
        re.IGNORECASE,
    )
    assert has_confirmation, (
        "Step 4.75 must require user confirmation before discarding changes. "
        "Automatic discard of uncommitted work is too destructive."
    )
