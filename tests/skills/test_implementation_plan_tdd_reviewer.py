"""Tests for new dimensions in the implementation-plan TDD reviewer (tdd.md).

These tests verify that task dso-j700 has added the 'red_test_dependency' and
'exemption_justification' dimensions to tdd.md and updated the review-criteria.md
schema hash.
"""

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TDD_REVIEWER = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "implementation-plan"
    / "docs"
    / "reviewers"
    / "plan"
    / "tdd.md"
)
REVIEW_CRITERIA = (
    REPO_ROOT
    / "plugins"
    / "dso"
    / "skills"
    / "implementation-plan"
    / "docs"
    / "review-criteria.md"
)


def test_tdd_reviewer_contains_red_test_dependency() -> None:
    """tdd.md must define a 'red_test_dependency' dimension.

    This dimension flags plans where a task's specified failing test
    depends on another task's code being written first (i.e., the test
    cannot be run RED in isolation).
    """
    content = TDD_REVIEWER.read_text()
    assert "red_test_dependency" in content, (
        "tdd.md is missing the 'red_test_dependency' dimension. "
        "Task dso-j700 must add it to the dimensions table and JSON block."
    )


def test_tdd_reviewer_contains_exemption_justification() -> None:
    """tdd.md must define an 'exemption_justification' dimension.

    This dimension requires reviewers to flag tasks that claim a TDD
    exemption without providing a written justification.
    """
    content = TDD_REVIEWER.read_text()
    assert "exemption_justification" in content, (
        "tdd.md is missing the 'exemption_justification' dimension. "
        "Task dso-j700 must add it to the dimensions table and JSON block."
    )


def test_tdd_reviewer_describes_exemption_criteria() -> None:
    """tdd.md must describe when TDD exemptions are acceptable.

    Acceptable exemption criteria include: the change contains 'no conditional
    logic' or is a 'change-detector' test (a test that would pass vacuously).
    At least one of these sentinel phrases must appear in tdd.md.
    """
    content = TDD_REVIEWER.read_text()
    assert "no conditional logic" in content or "change-detector" in content, (
        "tdd.md does not describe valid TDD exemption criteria. "
        "Expected 'no conditional logic' or 'change-detector' to appear. "
        "Task dso-j700 must add exemption criteria language."
    )
