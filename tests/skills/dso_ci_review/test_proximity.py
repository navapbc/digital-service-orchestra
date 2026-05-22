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


class TestEscapeRationaleDiffTextCriterion1:
    """validate_escape_rationale criterion 1: token-in-diff check via diff_text parameter."""

    def test_escape_rationale_fails_when_token_absent_from_diff(self) -> None:
        """Given: escape_text mentions 'validate_csrf_token' (not in diff_text), diff_text is non-empty
        When: validate_escape_rationale called with diff_text that lacks the token
        Then: returns False (criterion 1 fails — no token from escape_text found in diff_text)
        """
        escape_text = "The validate_csrf_token function at line 50 introduces a new security check"
        prior_cited_lines = ["auth/login.py:42"]
        overlap_region = ["auth/login.py:40-47"]
        diff_text = "+def handle_request(req):\n+    return req.process()\n"
        result = validate_escape_rationale(
            escape_text, prior_cited_lines, overlap_region, diff_text
        )
        assert result is False, (
            f"Expected False when no escape_text token appears in diff_text, got {result!r}"
        )

    def test_escape_rationale_passes_when_diff_text_empty(self) -> None:
        """Given: diff_text='' (default), escape_text has a token not in any diff
        When: validate_escape_rationale called with default diff_text
        Then: returns True (criterion 1 skipped when diff_text is empty; line 50 is outside overlap)
        """
        escape_text = (
            "The validate_csrf_token function at line 50 is a new security check"
        )
        prior_cited_lines = ["auth/login.py:42"]
        overlap_region = ["auth/login.py:40-47"]
        # diff_text defaults to '' — criterion 1 is skipped
        result = validate_escape_rationale(
            escape_text, prior_cited_lines, overlap_region
        )
        assert result is True, (
            f"Expected True when diff_text is empty (criterion 1 skipped) and line 50 is "
            f"outside overlap region, got {result!r}"
        )

    def test_escape_rationale_512_char_boundary(self) -> None:
        """Given: escape_text exactly 512 chars (schema max), diff_text contains a token from it
        When: validate_escape_rationale called with this boundary escape_text
        Then: returns True (not truncated; token found in diff; line 50 outside overlap)
        """
        # Build a 512-char escape_text that references line 50 and includes 'authentication'
        base = "authentication check at line 50 introduces new validation logic for the request"
        # Pad to exactly 512 chars with meaningful filler (short words excluded by >=4 filter)
        padding = " additional context note" * 20
        escape_text = (base + padding)[:512]
        assert len(escape_text) == 512

        prior_cited_lines = ["auth/login.py:42"]
        overlap_region = ["auth/login.py:40-47"]
        diff_text = "+def authentication(req):\n+    return req.validate()\n"
        result = validate_escape_rationale(
            escape_text, prior_cited_lines, overlap_region, diff_text
        )
        assert result is True, (
            f"Expected True for 512-char escape_text with token in diff and line 50 outside "
            f"overlap, got {result!r}"
        )
