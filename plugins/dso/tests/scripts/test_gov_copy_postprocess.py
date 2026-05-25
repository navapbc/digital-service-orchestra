"""Unit tests for gov_copy_postprocess.readability and gov_copy_postprocess.banned.

Covers task 012f-500c-e9de-494a (RED test for compute_fk_grade) and
task 20f1-51f5-4f06-4611 (RED test for find_banned_words).

DDs tested:
  - compute_fk_grade returns Flesch-Kincaid grade within 1e-6 of textstat
    reference value for a representative gov-copy sentence.
  - find_banned_words returns banned words found in text, case-insensitive,
    preserving first-occurrence order; returns [] when none found.

RED markers:
  test_compute_fk_grade_matches_textstat_reference
  test_find_banned_words_returns_matches_in_order
"""

from __future__ import annotations

import pytest
import textstat

from gov_copy_postprocess.readability import compute_fk_grade
from gov_copy_postprocess.banned import find_banned_words


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


@pytest.mark.unit
class TestFindBannedWords:
    """find_banned_words scans text for banned words, case-insensitively, in order."""

    # [test_find_banned_words_returns_matches_in_order]
    def test_find_banned_words_returns_matches_in_order(self) -> None:
        """Returns matched banned words in first-occurrence order."""
        text = "Please Utilize the portal and leverage data."
        banned: set[str] = {"utilize", "leverage"}
        result = find_banned_words(text, banned)
        assert result == ["utilize", "leverage"], (
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; "
            f"expected ['utilize', 'leverage'] in first-occurrence order"
        )

    def test_find_banned_words_returns_empty_when_no_match(self) -> None:
        """Returns empty list when no banned words appear in text."""
        text = "All good text."
        banned: set[str] = {"utilize"}
        result = find_banned_words(text, banned)
        assert result == [], (
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; "
            f"expected []"
        )

    def test_find_banned_words_case_insensitive(self) -> None:
        """Detects banned words regardless of capitalisation in the source text."""
        text = "LEVERAGE this UTILIZE that."
        banned: set[str] = {"leverage", "utilize"}
        result = find_banned_words(text, banned)
        # Both words must be detected; order follows first occurrence in text.
        assert set(result) == {"leverage", "utilize"}, (
            f"find_banned_words({text!r}, {banned!r}) returned {result!r}; "
            f"expected both 'leverage' and 'utilize' (case-insensitive)"
        )
        assert result.index("leverage") < result.index("utilize"), (
            "Expected 'leverage' to appear before 'utilize' (first-occurrence order)"
        )


# ---------------------------------------------------------------------------
# RED tests for is_active_voice — task 508b-9ca7-4317-4caa
# ---------------------------------------------------------------------------

from gov_copy_postprocess.voice import is_active_voice  # noqa: E402


@pytest.mark.unit
class TestIsActiveVoice:
    """is_active_voice returns True for active sentences, False for passive ones."""

    # [test_is_active_voice_active_sentence]
    def test_is_active_voice_active_sentence(self) -> None:
        """'You can apply online.' is an active-voice sentence."""
        assert is_active_voice("You can apply online.") is True, (
            "is_active_voice('You can apply online.') must return True"
        )

    def test_is_active_voice_passive_reviewed_by_staff(self) -> None:
        """'Applications are reviewed by staff.' is a passive-voice sentence."""
        assert is_active_voice("Applications are reviewed by staff.") is False, (
            "is_active_voice('Applications are reviewed by staff.') must return False"
        )

    def test_is_active_voice_passive_was_submitted(self) -> None:
        """'The form was submitted yesterday.' is a passive-voice sentence."""
        assert is_active_voice("The form was submitted yesterday.") is False, (
            "is_active_voice('The form was submitted yesterday.') must return False"
        )

    def test_is_active_voice_active_we_process(self) -> None:
        """'We process forms daily.' is an active-voice sentence."""
        assert is_active_voice("We process forms daily.") is True, (
            "is_active_voice('We process forms daily.') must return True"
        )
