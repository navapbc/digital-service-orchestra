"""Test that resolve-conflicts/SKILL.md requires user confirmation for individual ticket files.

TDD spec (RED before fix, GREEN after):
- The skill must NOT instruct agents to blindly accept the worktree version of ticket files
  using 'git checkout --ours -- .tickets/' or 'git merge -X ours'.
- The skill MUST require showing a diff and asking the user before resolving non-index
  ticket conflicts.
- The skill MAY auto-resolve .tickets/.index.json via the union merge driver.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "resolve-conflicts" / "SKILL.md"


def test_no_blind_ours_strategy_for_tickets() -> None:
    """resolve-conflicts/SKILL.md must not auto-resolve ticket files with 'ours' strategy.

    The dangerous pattern is instructing the agent to run:
      git checkout --ours -- .tickets/
    or:
      git merge -X ours
    without first showing a diff and getting user confirmation.

    The instruction must be wrapped in a NEVER prohibition. The NEVER prohibition
    itself may mention these patterns; only bare instructional lines (inside shell
    code blocks, or as imperative instructions without a NEVER prefix on the same line)
    are flagged.
    """
    content = SKILL_MD.read_text()

    # A "dangerous instruction" is a line that:
    #   1. Contains the dangerous pattern
    #   2. Is NOT the NEVER prohibition sentence itself (line starts with **NEVER or NEVER)
    #   3. Is NOT a comment-only line
    dangerous_lines = []
    lines = content.splitlines()
    for lineno, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("<!--") or stripped.startswith("#"):
            continue
        has_pattern = "checkout --ours -- .tickets/" in line or (
            "merge -X ours" in line and ".tickets" in line
        )
        if not has_pattern:
            continue
        # If the line itself is the NEVER prohibition, skip it
        if stripped.upper().startswith("NEVER") or stripped.startswith("**NEVER"):
            continue
        dangerous_lines.append((lineno, line))

    assert not dangerous_lines, (
        f"resolve-conflicts/SKILL.md contains {len(dangerous_lines)} unguarded "
        f"'ours' auto-resolve instruction(s) for .tickets/ files. "
        f"These must be prohibited with a NEVER guard:\n"
        + "\n".join(f"  line {ln}: {txt}" for ln, txt in dangerous_lines)
    )


def test_user_confirmation_required_for_ticket_md_conflicts() -> None:
    """resolve-conflicts/SKILL.md must require user confirmation for ticket .md conflicts.

    Individual ticket files (not .index.json) can contain important state from either
    the worktree or main. The skill must instruct the agent to show a diff and ask the
    user before choosing a version.
    """
    content = SKILL_MD.read_text()

    required_signals = [
        "diff",
        "user",
    ]
    missing = [sig for sig in required_signals if sig not in content.lower()]
    assert not missing, (
        f"resolve-conflicts/SKILL.md is missing required user-confirmation signals "
        f"for ticket file conflicts: {missing}"
    )

    # Must explicitly call out individual ticket .md files needing confirmation
    assert (
        "individual ticket" in content.lower()
        or ".tickets/*.md" in content
        or "ticket `.md`" in content
    ), (
        "resolve-conflicts/SKILL.md must explicitly require user confirmation for "
        "individual ticket .md files (not just .index.json)"
    )


def test_index_json_auto_resolve_still_present() -> None:
    """resolve-conflicts/SKILL.md must still auto-resolve .tickets/.index.json via union driver.

    The union merge driver for .index.json is safe (additive union). This auto-resolve
    must be preserved — only individual ticket files require user confirmation.
    """
    content = SKILL_MD.read_text()
    assert "merge-ticket-index.py" in content or ".index.json" in content, (
        "resolve-conflicts/SKILL.md must retain auto-resolve logic for "
        ".tickets/.index.json via merge-ticket-index.py"
    )
