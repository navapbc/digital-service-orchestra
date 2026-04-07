"""Tests for Testing Mode Classification in implementation-plan/SKILL.md.

TDD spec for task 4138-71ce (RED task):
- SKILL.md must contain a "Testing Mode Classification" section defining:
  1. RED mode — new behavioral content, no existing tests
  2. GREEN mode — pure refactor, no behavior change
  3. UPDATE mode — existing file with observable behavior change
- Task description template must contain "## Testing Mode" header
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def test_skill_md_contains_testing_mode_classification_section() -> None:
    """SKILL.md must contain a 'Testing Mode Classification' section."""
    content = _read_skill()
    assert "Testing Mode Classification" in content, (
        "Expected SKILL.md to contain a 'Testing Mode Classification' section "
        "that defines the RED, GREEN, and UPDATE modes for task planning."
    )


def test_skill_md_testing_mode_defines_red_mode() -> None:
    """Testing Mode Classification section must define the RED mode."""
    content = _read_skill()
    # The section uses bold **RED** in the table
    assert "**RED**" in content, (
        "Expected SKILL.md Testing Mode Classification to define RED mode "
        "(new behavioral content with no existing tests)."
    )


def test_skill_md_testing_mode_defines_green_mode() -> None:
    """Testing Mode Classification section must define the GREEN mode."""
    content = _read_skill()
    assert "**GREEN**" in content, (
        "Expected SKILL.md Testing Mode Classification to define GREEN mode "
        "(pure refactor — existing tests remain correct without modification)."
    )


def test_skill_md_testing_mode_defines_update_mode() -> None:
    """Testing Mode Classification section must define the UPDATE mode."""
    content = _read_skill()
    assert "**UPDATE**" in content, (
        "Expected SKILL.md Testing Mode Classification to define UPDATE mode "
        "(existing file with observable behavior change)."
    )


def test_skill_md_task_description_template_contains_testing_mode_header() -> None:
    """Task description template must contain '## Testing Mode' header."""
    content = _read_skill()
    assert "## Testing Mode" in content, (
        "Expected SKILL.md task description template to contain '## Testing Mode' "
        "header so that each task ticket records its RED/GREEN/UPDATE classification."
    )
