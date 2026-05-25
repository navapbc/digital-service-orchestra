"""Unit tests for gov_copy_postprocess.readability.

Covers task 012f-500c-e9de-494a (RED test for compute_fk_grade).

DDs tested:
  - compute_fk_grade returns Flesch-Kincaid grade within 1e-6 of textstat
    reference value for a representative gov-copy sentence.

RED marker (before readability.py exists):
  test_compute_fk_grade_matches_textstat_reference
"""

from __future__ import annotations

import pytest
import textstat

from gov_copy_postprocess.readability import compute_fk_grade


SAMPLE_TEXT = "You can apply for benefits online."


@pytest.mark.unit
class TestComputeFkGrade:
    """compute_fk_grade delegates to textstat.flesch_kincaid_grade."""

    # [test_compute_fk_grade_matches_textstat_reference]
    def test_compute_fk_grade_matches_textstat_reference(self) -> None:
        """compute_fk_grade must match textstat.flesch_kincaid_grade within 1e-6."""
        expected = textstat.flesch_kincaid_grade(SAMPLE_TEXT)
        result = compute_fk_grade(SAMPLE_TEXT)
        assert abs(result - expected) < 1e-6, (
            f"compute_fk_grade({SAMPLE_TEXT!r}) returned {result!r}; "
            f"expected {expected!r} (within 1e-6)"
        )
