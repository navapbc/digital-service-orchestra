"""Tests asserting fix-task-tdd.md and fix-task-mechanical.md contain retirement notices.

TDD spec for task w21-0xmw (RED task):
- plugins/dso/skills/debug-everything/prompts/fix-task-tdd.md must:
  1. Contain a deprecation notice or forward pointer to dso:fix-bug
  2. NOT claim to be the primary path for bug resolution without redirecting to dso:fix-bug
- plugins/dso/skills/debug-everything/prompts/fix-task-mechanical.md must:
  1. Contain a deprecation notice or forward pointer to dso:fix-bug
  2. NOT claim to be the primary path for bug resolution without redirecting to dso:fix-bug

All tests in this file must FAIL (RED) before the prompt updates in the next task (w21-mx5s).
Run: python -m pytest tests/skills/test_fix_task_prompts_retired.py -v to confirm RED.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX_TASK_TDD = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "debug-everything"
    / "prompts"
    / "fix-task-tdd.md"
)
FIX_TASK_MECHANICAL = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "debug-everything"
    / "prompts"
    / "fix-task-mechanical.md"
)

_RETIREMENT_PHRASES = (
    "deprecated",
    "DEPRECATED",
    "forward pointer",
    "dso:fix-bug",
    "use dso:fix-bug instead",
    "use /dso:fix-bug",
    "/dso:fix-bug",
    "this prompt is retired",
    "retired",
    "use fix-bug instead",
)


def _has_retirement_marker(content: str) -> bool:
    """Return True if any retirement/forward-pointer phrase is present."""
    return any(phrase in content for phrase in _RETIREMENT_PHRASES)


def test_fix_task_tdd_contains_deprecation_notice() -> None:
    """fix-task-tdd.md must contain a deprecation notice or forward pointer to dso:fix-bug.

    After the fix-bug skill was created to centralise bug resolution routing,
    fix-task-tdd.md must be retired so agents are not routed to it directly.
    The file must contain language that marks it as deprecated and redirects
    to /dso:fix-bug as the canonical path for TDD-style bug resolution.
    This is a RED test — the file does not yet contain this language.
    """
    content = FIX_TASK_TDD.read_text()
    assert _has_retirement_marker(content), (
        f"Expected {FIX_TASK_TDD} to contain a deprecation notice or forward pointer "
        "to dso:fix-bug. Acceptable phrases include: "
        + ", ".join(repr(p) for p in _RETIREMENT_PHRASES)
        + ". "
        "This is a RED test — fix-task-tdd.md does not yet contain retirement language. "
        "The GREEN task (w21-mx5s) will add the forward pointer."
    )


def test_fix_task_mechanical_contains_deprecation_notice() -> None:
    """fix-task-mechanical.md must contain a deprecation notice or forward pointer to dso:fix-bug.

    After the fix-bug skill was created to centralise bug resolution routing,
    fix-task-mechanical.md must be retired so agents are not routed to it directly.
    The file must contain language that marks it as deprecated and redirects
    to /dso:fix-bug as the canonical path for mechanical bug resolution.
    This is a RED test — the file does not yet contain this language.
    """
    content = FIX_TASK_MECHANICAL.read_text()
    assert _has_retirement_marker(content), (
        f"Expected {FIX_TASK_MECHANICAL} to contain a deprecation notice or forward pointer "
        "to dso:fix-bug. Acceptable phrases include: "
        + ", ".join(repr(p) for p in _RETIREMENT_PHRASES)
        + ". "
        "This is a RED test — fix-task-mechanical.md does not yet contain retirement language. "
        "The GREEN task (w21-mx5s) will add the forward pointer."
    )


def test_fix_task_tdd_does_not_claim_primary_path_without_redirect() -> None:
    """fix-task-tdd.md must not claim to be the primary bug resolution path without a redirect.

    The file currently presents itself as a direct execution template for TDD-style bug
    fixing. After retirement, it must either be entirely replaced by a forward pointer
    or must include a redirect so that any agent landing on this file is directed to
    /dso:fix-bug instead of executing the template instructions directly.
    This is a RED test — the file does not yet contain the required redirect.
    """
    content = FIX_TASK_TDD.read_text()

    # The file currently has "## Fix: {issue title}" as its primary heading,
    # presenting itself as a direct fix template without any redirect to dso:fix-bug.
    has_primary_fix_heading = "## Fix:" in content
    has_redirect = _has_retirement_marker(content)

    assert not (has_primary_fix_heading and not has_redirect), (
        "fix-task-tdd.md presents itself as a primary fix template (contains '## Fix:') "
        "without a redirect to /dso:fix-bug. "
        "After retirement, the file must contain a forward pointer so agents are "
        "directed to /dso:fix-bug rather than executing this template directly. "
        "This is a RED test — the redirect does not yet exist."
    )


def test_fix_task_mechanical_does_not_claim_primary_path_without_redirect() -> None:
    """fix-task-mechanical.md must not claim to be the primary bug resolution path without a redirect.

    The file currently presents itself as a direct execution template for mechanical bug
    fixing. After retirement, it must either be entirely replaced by a forward pointer
    or must include a redirect so that any agent landing on this file is directed to
    /dso:fix-bug instead of executing the template instructions directly.
    This is a RED test — the file does not yet contain the required redirect.
    """
    content = FIX_TASK_MECHANICAL.read_text()

    # The file currently has "## Fix: {issue title}" as its primary heading,
    # presenting itself as a direct fix template without any redirect to dso:fix-bug.
    has_primary_fix_heading = "## Fix:" in content
    has_redirect = _has_retirement_marker(content)

    assert not (has_primary_fix_heading and not has_redirect), (
        "fix-task-mechanical.md presents itself as a primary fix template (contains '## Fix:') "
        "without a redirect to /dso:fix-bug. "
        "After retirement, the file must contain a forward pointer so agents are "
        "directed to /dso:fix-bug rather than executing this template directly. "
        "This is a RED test — the redirect does not yet exist."
    )
