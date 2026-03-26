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


def test_tdd_reviewer_bidirectional_dimension() -> None:
    """tdd.md must define a 'bidirectional_test_coverage' dimension.

    This dimension ensures that implementation plans cover not only
    tasks that create new behavior (tested with new tests) but also
    tasks that modify or remove existing behavior — which require
    corresponding test updates or deletions. A plan that only adds
    new tests for new code but leaves stale tests for removed behavior
    fails this dimension.
    """
    content = TDD_REVIEWER.read_text()
    assert "bidirectional_test_coverage" in content, (
        "tdd.md is missing the 'bidirectional_test_coverage' dimension. "
        "The dimension must be added to the dimensions table and JSON block "
        "to ensure modify/remove/create tasks are all test-covered."
    )


def test_tdd_reviewer_scoring_modify_remove() -> None:
    """tdd.md scoring criteria must reference modify-test and remove-test tasks.

    The 'bidirectional_test_coverage' dimension's scoring guidance should
    explicitly address how to evaluate tasks that modify existing behavior
    (requiring test updates) and tasks that delete behavior (requiring test
    removal or inversion). These phrases — 'modify' and 'remove' — must
    appear in the tdd.md scoring guidance for this dimension.
    """
    content = TDD_REVIEWER.read_text()
    # Both scoring guidance keywords must be present in context of bidirectional coverage
    assert "modify" in content and "remove" in content, (
        "tdd.md scoring criteria for 'bidirectional_test_coverage' must mention "
        "both 'modify' (modify-test tasks) and 'remove' (remove-test tasks). "
        "Add concrete scoring guidance for each task type."
    )
    # Verify the dimension is present before checking scoring specifics
    assert "bidirectional_test_coverage" in content, (
        "tdd.md is missing the 'bidirectional_test_coverage' dimension entirely. "
        "Add the dimension before adding scoring criteria."
    )


def test_tdd_reviewer_below_4_missing_bidirectional() -> None:
    """tdd.md 'below 4' criteria must describe plans lacking modify/remove test tasks.

    For the 'bidirectional_test_coverage' dimension, the 'below 4' column of
    the scoring table must explain what a deficient plan looks like: one that
    adds new tests for new behavior but omits test updates for modified behavior
    or test deletions for removed behavior. The guidance must make it clear that
    one-directional test coverage (create-only) is insufficient.
    """
    content = TDD_REVIEWER.read_text()
    assert "bidirectional_test_coverage" in content, (
        "tdd.md is missing the 'bidirectional_test_coverage' dimension. "
        "The 'below 4' scoring criteria cannot be verified without the dimension."
    )
    # The 'below 4' guidance should flag plans that only add new tests
    # without addressing modified or deleted behavior
    assert "stale" in content or "one-directional" in content or "omit" in content, (
        "tdd.md 'below 4' criteria for 'bidirectional_test_coverage' must describe "
        "plans that lack modify/remove test tasks for changed/deleted behavior. "
        "Expected at least one of: 'stale', 'one-directional', 'omit' to appear."
    )
