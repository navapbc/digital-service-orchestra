"""Behavioral tests for speculation_markers module.

GREEN: all tests should pass once speculation_markers.py is in place.

GREEN marker: tests/skills/dso_ci_review/test_speculation_markers.py
"""

from __future__ import annotations

from dso_ci_review.speculation_markers import (
    count_speculation_markers,
    speculation_marker_frequency,
)


class TestCountSpeculationMarkersEmpty:
    """count_speculation_markers returns 0 for an empty findings list."""

    def test_count_markers_empty_findings(self) -> None:
        """Given: an empty findings list
        When: count_speculation_markers is called
        Then: returns 0
        """
        result = count_speculation_markers([])
        assert result == 0, f"Expected 0 for empty findings, got {result}"


class TestCountSpeculationMarkersClean:
    """count_speculation_markers returns 0 for a finding with no speculation language."""

    def test_count_markers_clean_finding(self) -> None:
        """Given: a single finding whose description contains no speculation markers
        When: count_speculation_markers is called
        Then: returns 0
        """
        findings = [
            {"severity": "minor", "description": "The function lacks input validation."}
        ]
        result = count_speculation_markers(findings)
        assert result == 0, f"Expected 0 for clean finding, got {result}"


class TestCountSpeculationMarkersWithMay:
    """count_speculation_markers counts the 'may ' marker correctly."""

    def test_count_markers_finding_with_may(self) -> None:
        """Given: a single finding whose description contains exactly one 'may ' occurrence
        When: count_speculation_markers is called
        Then: returns 1
        """
        findings = [
            {"severity": "important", "description": "This may cause issues at scale."}
        ]
        result = count_speculation_markers(findings)
        assert result == 1, f"Expected 1 for finding with 'may ', got {result}"


class TestFrequencyAllClean:
    """speculation_marker_frequency returns 0.0 when no findings contain markers."""

    def test_frequency_all_clean(self) -> None:
        """Given: two findings with no speculation language
        When: speculation_marker_frequency is called
        Then: returns 0.0
        """
        findings = [
            {"description": "The loop index is off by one."},
            {"description": "Return value is not checked."},
        ]
        result = speculation_marker_frequency(findings)
        assert result == 0.0, f"Expected 0.0 for all-clean findings, got {result}"


class TestFrequencyAllSpeculation:
    """speculation_marker_frequency returns 1.0 when every finding contains a marker."""

    def test_frequency_all_speculation(self) -> None:
        """Given: two findings both containing at least one speculation marker
        When: speculation_marker_frequency is called
        Then: returns 1.0
        """
        findings = [
            {"description": "This might break under concurrency."},
            {"description": "Possibly missing null check."},
        ]
        result = speculation_marker_frequency(findings)
        assert result == 1.0, f"Expected 1.0 for all-speculation findings, got {result}"


class TestFrequencyPartial:
    """speculation_marker_frequency returns 0.5 when half the findings contain markers."""

    def test_frequency_partial(self) -> None:
        """Given: two findings where one contains a speculation marker and one does not
        When: speculation_marker_frequency is called
        Then: returns 0.5
        """
        findings = [
            {"description": "Hard to tell without more context whether this is safe."},
            {"description": "Missing error boundary around the async call."},
        ]
        result = speculation_marker_frequency(findings)
        assert result == 0.5, (
            f"Expected 0.5 for half-speculation findings, got {result}"
        )
