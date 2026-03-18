"""Tests for new dimensions in the implementation-plan TDD reviewer (tdd.md).

All tests are xfail(strict=True) — they must fail until task dso-j700 adds the
'red_test_dependency' and 'exemption_justification' dimensions to tdd.md and
updates the review-criteria.md schema hash.
"""

import pathlib

import pytest

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


@pytest.mark.xfail(
    strict=True, reason="dso-j700: red_test_dependency not yet added to tdd.md"
)
def test_tdd_reviewer_contains_red_test_dependency() -> None:
    """tdd.md must define a 'red_test_dependency' dimension.

    This dimension will flag plans where a task's specified failing test
    depends on another task's code being written first (i.e., the test
    cannot be run RED in isolation).
    """
    content = TDD_REVIEWER.read_text()
    assert "red_test_dependency" in content, (
        "tdd.md is missing the 'red_test_dependency' dimension. "
        "Task dso-j700 must add it."
    )


@pytest.mark.xfail(
    strict=True, reason="dso-j700: exemption_justification not yet added to tdd.md"
)
def test_tdd_reviewer_contains_exemption_justification() -> None:
    """tdd.md must define an 'exemption_justification' dimension.

    This dimension will require reviewers to flag tasks that claim a TDD
    exemption without providing a written justification.
    """
    content = TDD_REVIEWER.read_text()
    assert "exemption_justification" in content, (
        "tdd.md is missing the 'exemption_justification' dimension. "
        "Task dso-j700 must add it."
    )


@pytest.mark.xfail(
    strict=True,
    reason="dso-j700: exemption criteria description not yet added to tdd.md",
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


@pytest.mark.xfail(
    strict=True,
    reason="dso-j700: review-criteria.md still contains old hash ae8bfc7bd9a0d7e3",
)
def test_review_criteria_old_hash_absent() -> None:
    """review-criteria.md must not contain the stale schema hash 'ae8bfc7bd9a0d7e3'.

    Precondition: the file exists and is non-empty (guards against vacuous pass
    if the file is deleted).

    # NOTE: This test passes vacuously if review-criteria.md is deleted.
    # Acceptable risk — file deletion would fail other tests.
    """
    assert REVIEW_CRITERIA.exists(), (
        "review-criteria.md does not exist — cannot assert hash absence."
    )
    content = REVIEW_CRITERIA.read_text()
    assert len(content) > 0, "review-criteria.md is empty — cannot assert hash absence."

    assert "ae8bfc7bd9a0d7e3" not in content, (
        "review-criteria.md still contains the old schema hash 'ae8bfc7bd9a0d7e3'. "
        "Task dso-j700 must update the hash after adding new TDD dimensions."
    )
