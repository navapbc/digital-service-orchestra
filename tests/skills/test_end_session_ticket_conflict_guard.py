"""Test that end-session/SKILL.md prohibits blind 'ours' resolution for ticket conflicts.

TDD spec (RED before fix, GREEN after):
- Step 4 of the end-session skill must include a CRITICAL guard explicitly prohibiting
  'git merge -X ours' and 'git checkout --ours -- .tickets/' for ticket conflicts.
- The guard must direct agents to invoke /dso:resolve-conflicts instead, which shows
  diffs and asks the user for confirmation.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "end-session" / "SKILL.md"


def test_end_session_step4_prohibits_blind_ours_for_tickets() -> None:
    """end-session/SKILL.md Step 4 must prohibit blind 'ours' resolution for ticket files.

    The skill must contain an explicit instruction that agents must NOT use
    'git merge -X ours' or 'git checkout --ours' for .tickets/ conflicts.
    """
    content = SKILL_MD.read_text()

    # Verify the prohibition is present
    has_prohibition = (
        ("merge -X ours" in content and "do NOT" in content)
        or ("checkout --ours" in content and "do NOT" in content)
        or ("CRITICAL" in content and "ticket" in content.lower() and "ours" in content)
    )
    assert has_prohibition, (
        "end-session/SKILL.md Step 4 must contain an explicit CRITICAL prohibition "
        "against using 'git merge -X ours' or 'git checkout --ours -- .tickets/' "
        "for ticket file conflicts."
    )


def test_end_session_step4_directs_to_resolve_conflicts_for_tickets() -> None:
    """end-session/SKILL.md Step 4 must direct agents to /dso:resolve-conflicts for ticket conflicts."""
    content = SKILL_MD.read_text()

    # The ticket conflict guard must mention resolve-conflicts as the correct path
    assert "/dso:resolve-conflicts" in content, (
        "end-session/SKILL.md must direct agents to invoke /dso:resolve-conflicts "
        "when ticket file conflicts occur, not resolve them autonomously."
    )

    # The guard must explain WHY (main may have updates from another worktree)
    has_rationale = (
        "another worktree" in content.lower()
        or "main may have" in content.lower()
        or "received ticket updates" in content.lower()
    )
    assert has_rationale, (
        "end-session/SKILL.md ticket conflict guard must explain the rationale: "
        "main may have received ticket updates from another worktree."
    )
