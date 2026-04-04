"""RED tests for re-invocation guard language in implementation-plan/SKILL.md.

TDD spec for task 40f8-0759 (RED task):
All tests MUST FAIL against the current SKILL.md (which lacks a re-invocation
guard section). Task d16d-1419 (GREEN) will add the guard and make these pass.

Assertions:
1. test_skill_contains_reinvocation_guard_heading: guard section exists
2. test_skill_references_include_archived: '--include-archived' flag documented
3. test_skill_classifies_closed_children_readonly: 'read-only' near 'closed'
4. test_skill_classifies_inprogress_children_flagged: 'flagged' near 'in-progress'
5. test_skill_produces_diff_plan: 'new or reopened' or 'diff plan' present
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def test_skill_contains_reinvocation_guard_heading() -> None:
    """SKILL.md must contain a re-invocation guard section heading.

    When /dso:implementation-plan is called on a story that already has tasks,
    the skill must detect the existing work and present a structured diff plan
    rather than silently creating duplicate tasks. The guard section must be
    named with 're-invocation' or 'reinvocation' language.
    """
    content = _read_skill()
    assert (
        "Re-invocation" in content
        or "re-invocation" in content
        or "reinvocation" in content
    ), (
        "Expected SKILL.md to contain a re-invocation guard section "
        "(e.g., '## Re-invocation Guard' or '### Re-invocation Guard'). "
        "This section protects against duplicate task creation when the skill "
        "is called on a story that already has child tasks."
    )


def test_skill_references_include_archived() -> None:
    """SKILL.md must reference '--include-archived' for archived child task handling.

    When checking whether a story already has tasks, the guard must use
    '--include-archived' to detect archived/closed children, not just active ones.
    This prevents re-invocation from ignoring previously completed work.
    """
    content = _read_skill()
    assert "--include-archived" in content, (
        "Expected SKILL.md to reference '--include-archived' in the re-invocation "
        "guard logic. This flag is needed to detect archived child tasks when "
        "determining whether the story has been previously planned."
    )


def test_skill_classifies_closed_children_readonly() -> None:
    """SKILL.md must classify closed child tasks as read-only in the diff plan.

    When re-invoked, the guard must categorize already-closed child tasks as
    'read-only' — they should not be modified, deleted, or recreated. The word
    'read-only' must appear within 5 lines of 'closed' in the SKILL.md content.
    """
    content = _read_skill()
    lines = content.splitlines()
    for i, line in enumerate(lines):
        if "closed" in line.lower():
            window_start = max(0, i - 5)
            window_end = min(len(lines), i + 6)
            window = "\n".join(lines[window_start:window_end])
            if "read-only" in window:
                return
    assert False, (
        "Expected SKILL.md to classify closed child tasks as 'read-only' in the "
        "re-invocation guard. The phrase 'read-only' must appear within 5 lines "
        "of 'closed' in the SKILL.md content to indicate that closed tasks must "
        "not be modified during re-invocation."
    )


def test_skill_classifies_inprogress_children_flagged() -> None:
    """SKILL.md must classify in-progress child tasks as flagged in the diff plan.

    When re-invoked, the guard must flag in-progress child tasks for user attention.
    The word 'flagged' must appear within 5 lines of 'in-progress' or 'in_progress'
    in the SKILL.md content.
    """
    content = _read_skill()
    lines = content.splitlines()
    for i, line in enumerate(lines):
        if "in-progress" in line.lower() or "in_progress" in line.lower():
            window_start = max(0, i - 5)
            window_end = min(len(lines), i + 6)
            window = "\n".join(lines[window_start:window_end])
            if "flagged" in window:
                return
    assert False, (
        "Expected SKILL.md to classify in-progress child tasks as 'flagged' in the "
        "re-invocation guard. The phrase 'flagged' must appear within 5 lines of "
        "'in-progress' or 'in_progress' in the SKILL.md content to indicate that "
        "active tasks require user attention during re-invocation."
    )


def test_skill_produces_diff_plan() -> None:
    """SKILL.md must describe a diff plan output for re-invocation scenarios.

    The re-invocation guard must produce a diff plan showing which tasks are
    new or need to be reopened, rather than recreating all tasks from scratch.
    SKILL.md must contain either 'new or reopened' or 'diff plan' to document
    this behavior.
    """
    content = _read_skill()
    assert "new or reopened" in content or "diff plan" in content, (
        "Expected SKILL.md to describe a diff plan for re-invocation. "
        "The guard must produce a structured output showing which tasks are "
        "'new or reopened' (or a 'diff plan') rather than recreating all tasks. "
        "Neither 'new or reopened' nor 'diff plan' was found in SKILL.md."
    )
