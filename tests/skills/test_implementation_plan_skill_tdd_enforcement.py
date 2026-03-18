"""Tests for TDD enforcement language in implementation-plan/SKILL.md.

TDD spec for task dso-awsv (GREEN task):
- SKILL.md Step 3 must contain explicit TDD enforcement rules covering:
  1. 'no conditional logic' — ban on conditional/parametric logic in tests
  2. 'change-detector test' — escape hatch terminology
  3. 'infrastructure-boundary-only' — scope qualifier for escape hatch
  4. 'RED test task' — required naming for the failing-test task
  5. 'behavioral content' — definition distinguishing real tests from test stubs
  6. Integration test task rule language
  7. 'existing coverage' — prohibition on relying on pre-existing tests
  8. 'no test environment' — prohibition on writing tests needing special env
  9. Justification requirement for escape hatch use

All tests are marked xfail(strict=True) because SKILL.md has not yet been
updated by dso-awsv. They will turn GREEN once dso-awsv lands its changes.
"""

import pathlib

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_no_conditional_logic() -> None:
    """SKILL.md must prohibit conditional/parametric logic in TDD test tasks."""
    content = _read_skill()
    assert "no conditional logic" in content, (
        "SKILL.md Step 3 must contain 'no conditional logic' to prohibit "
        "parametric test stubs that always pass."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_change_detector_test() -> None:
    """SKILL.md must name the escape hatch anti-pattern as 'change-detector test'."""
    content = _read_skill()
    assert "change-detector test" in content, (
        "SKILL.md Step 3 must reference 'change-detector test' as the "
        "canonical name for the escape hatch anti-pattern."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_infrastructure_boundary_only() -> None:
    """SKILL.md must restrict escape hatch to infrastructure-boundary-only cases."""
    content = _read_skill()
    assert "infrastructure-boundary-only" in content, (
        "SKILL.md Step 3 must contain 'infrastructure-boundary-only' to scope "
        "when the change-detector test escape hatch is permitted."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_red_test_task() -> None:
    """SKILL.md must require a named 'RED test task' as a distinct task in the plan."""
    content = _read_skill()
    assert "RED test task" in content, (
        "SKILL.md Step 3 must require a 'RED test task' as a standalone task "
        "that writes the failing test before implementation."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_behavioral_content() -> None:
    """SKILL.md must define 'behavioral content' to distinguish real tests."""
    content = _read_skill()
    assert "behavioral content" in content, (
        "SKILL.md Step 3 must use 'behavioral content' to distinguish tests "
        "with real assertions from empty stubs or pass-through fixtures."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_integration_test_task_rule() -> None:
    """SKILL.md must include rule language governing integration test tasks."""
    content = _read_skill()
    assert "integration test task" in content, (
        "SKILL.md Step 3 must contain 'integration test task' rule language "
        "specifying how integration tests fit into the TDD task structure."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_existing_coverage() -> None:
    """SKILL.md must prohibit relying on existing coverage to satisfy RED."""
    content = _read_skill()
    assert "existing coverage" in content, (
        "SKILL.md Step 3 must reference 'existing coverage' to clarify that "
        "pre-existing passing tests do not satisfy the RED requirement."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_no_test_environment() -> None:
    """SKILL.md must prohibit tests that require a special test environment."""
    content = _read_skill()
    assert "no test environment" in content, (
        "SKILL.md Step 3 must contain 'no test environment' to prohibit "
        "writing tests that require special setup unavailable in CI."
    )


@pytest.mark.xfail(strict=True, reason="RED: SKILL.md not yet updated by dso-awsv")
def test_skill_md_contains_justification_requirement() -> None:
    """SKILL.md must require a written justification when invoking the escape hatch."""
    content = _read_skill()
    assert "justification requirement" in content, (
        "SKILL.md Step 3 must contain 'justification requirement' to require "
        "agents to document why the change-detector test escape hatch was invoked."
    )
