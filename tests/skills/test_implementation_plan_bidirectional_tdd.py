"""Tests for bidirectional TDD and file impact enumeration in implementation-plan/SKILL.md.

TDD spec for task aac3-f70e (RED task):
These tests verify that implementation-plan SKILL.md contains:
  1. File impact enumeration step
  2. Fuzzy-match reference for test association
  3. Modify-existing-test task type
  4. Remove-test task type
  5. Behavioral specification reinforcement
  6. File impact test table structure

Metadata/schema validation: skill files define normative agent instruction vocabulary.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "implementation-plan" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_MD.read_text()


def test_skill_contains_file_impact_enumeration() -> None:
    """SKILL.md must contain a file impact enumeration step."""
    content = _read_skill()
    assert "file impact" in content, (
        "Expected SKILL.md to contain 'file impact' to instruct agents to enumerate "
        "all files affected by a story before decomposing into tasks."
    )


def test_skill_references_fuzzy_match_for_test_association() -> None:
    """SKILL.md must reference fuzzy-match for test discovery."""
    content = _read_skill()
    assert any(
        term in content
        for term in ("fuzzy_find_associated_tests", "fuzzy-match.sh", "fuzzy match")
    ), (
        "Expected SKILL.md to reference 'fuzzy_find_associated_tests', 'fuzzy-match.sh', "
        "or 'fuzzy match' to guide agents toward the canonical test-association mechanism."
    )


def test_skill_defines_modify_existing_test_task_type() -> None:
    """SKILL.md must define a modify/update existing test task type."""
    content = _read_skill()
    assert any(
        term in content
        for term in (
            "modify existing test",
            "update existing test",
            "modify-existing-test",
        )
    ), (
        "Expected SKILL.md to define a modify/update existing test task type "
        "for changed-behavior scenarios where the RED test edits an existing file."
    )


def test_skill_defines_remove_test_task_type() -> None:
    """SKILL.md must define a remove-test task type."""
    content = _read_skill()
    assert any(
        term in content
        for term in ("remove test", "remove-test", "delete test", "delete-test")
    ), (
        "Expected SKILL.md to define a remove-test task type for deleted-behavior "
        "scenarios where obsolete test assertions must be cleaned up."
    )


def test_skill_reinforces_behavioral_specification() -> None:
    """SKILL.md must reinforce that RED tests may modify existing tests."""
    content = _read_skill()
    assert any(
        term in content
        for term in (
            "modify existing tests",
            "modifying existing tests",
            "not only create new",
            "existing test files",
        )
    ), (
        "Expected SKILL.md to reinforce that RED tests may modify existing tests, "
        "not only create new test files, to capture changed or removed behavior."
    )


def test_skill_contains_file_impact_test_table() -> None:
    """SKILL.md must contain a file impact table structure."""
    content = _read_skill()
    assert any(
        term in content
        for term in (
            "source →",
            "source->",
            "action →",
            "action->",
            "file impact table",
            "impact table",
        )
    ), (
        "Expected SKILL.md to contain a source→action→tests classification structure "
        "(file impact table) to guide agents in producing auditable task breakdowns."
    )
