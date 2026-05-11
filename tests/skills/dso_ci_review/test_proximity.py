"""RED tests for compute_proximity_overlap and validate_escape_rationale (proximity.py).

These tests FAIL until the implementation task adds compute_proximity_overlap and
validate_escape_rationale to dso_ci_review.proximity.

RED marker: tests/skills/dso_ci_review/test_proximity.py [test_proximity_overlap_same_file_within_5_lines]
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[3] / "plugins" / "dso" / "scripts"))

# Module does not exist yet — importing will raise ImportError until the
# implementation task creates dso_ci_review/proximity.py.
from dso_ci_review.proximity import compute_proximity_overlap, validate_escape_rationale  # noqa: F401


class TestProximityOverlapWithinRange:
    """compute_proximity_overlap returns True when lines are within ±5 of each other."""

    def test_proximity_overlap_same_file_within_5_lines(self) -> None:
        """Given: finding cited_lines = ['auth/login.py:42'], prior cited_lines = ['auth/login.py:40'] (within ±5)
        When: compute_proximity_overlap(finding_lines, prior_lines) called
        Then: returns True
        """
        finding_lines = ["auth/login.py:42"]
        prior_lines = ["auth/login.py:40"]
        result = compute_proximity_overlap(finding_lines, prior_lines)
        assert result is True, (
            f"Expected True when lines are within ±5 (42 vs 40), got {result!r}"
        )


class TestProximityOverlapOutsideRange:
    """compute_proximity_overlap returns False when lines are more than ±5 apart."""

    def test_proximity_overlap_same_file_outside_5_lines(self) -> None:
        """Given: finding cited_lines = ['auth/login.py:42'], prior cited_lines = ['auth/login.py:10'] (>5 lines away)
        When: compute_proximity_overlap(finding_lines, prior_lines) called
        Then: returns False
        """
        finding_lines = ["auth/login.py:42"]
        prior_lines = ["auth/login.py:10"]
        result = compute_proximity_overlap(finding_lines, prior_lines)
        assert result is False, (
            f"Expected False when lines are >5 apart (42 vs 10), got {result!r}"
        )


class TestEscapeRationaleValid:
    """validate_escape_rationale returns True when escape text references tokens outside prior/overlap region."""

    def test_escape_rationale_valid_when_references_non_overlap_token(self) -> None:
        """Given: escape_text references line 50, prior_cited_lines has line 42, overlap region is 40-47
        When: validate_escape_rationale(escape_text, prior_cited_lines, overlap_region) called
        Then: returns True (line 50 is outside the overlap region)
        """
        escape_text = "New import statement at line 50 not present in prior findings"
        prior_cited_lines = ["auth/login.py:42"]
        overlap_region = ["auth/login.py:40-47"]
        result = validate_escape_rationale(
            escape_text, prior_cited_lines, overlap_region
        )
        assert result is True, (
            f"Expected True when escape text references line 50 (outside overlap 40-47), "
            f"got {result!r}"
        )


class TestEscapeRationaleInvalid:
    """validate_escape_rationale returns False when escape text only references tokens in prior/overlap region."""

    def test_escape_rationale_invalid_when_only_references_prior_tokens(self) -> None:
        """Given: escape_text references line 42, prior_cited_lines has line 42, overlap region is 40-47
        When: validate_escape_rationale(escape_text, prior_cited_lines, overlap_region) called
        Then: returns False (line 42 is in both prior and overlap region)
        """
        escape_text = "Same token at line 42 is different context"
        prior_cited_lines = ["auth/login.py:42"]
        overlap_region = ["auth/login.py:40-47"]
        result = validate_escape_rationale(
            escape_text, prior_cited_lines, overlap_region
        )
        assert result is False, (
            f"Expected False when escape text only references line 42 which is in "
            f"prior_cited_lines and overlap region, got {result!r}"
        )
