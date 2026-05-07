"""Speculation marker detection for reviewer findings quality analysis.

Used by ci-review-corpus-delta.sh (via Python -c or import) to measure
how often reviewer findings contain hedging language that indicates the
reviewer is guessing without enough context.
"""

from __future__ import annotations

SPECULATION_MARKERS = [
    "may ",
    "might ",
    "could be",
    "possibly",
    "unclear if",
    "hard to tell",
    "without more context",
    "assuming",
    "it seems",
    "appears to",
    "probably",
    "perhaps",
]


def _description(finding: dict) -> str:
    """Return the description field of a finding, normalised to lower-case."""
    return (finding.get("description") or "").lower()


def count_speculation_markers(findings: list[dict]) -> int:
    """Count total speculation marker occurrences across all finding descriptions.

    Each marker occurrence in each finding description is counted individually,
    so a single description containing both "may " and "possibly" contributes 2.
    """
    total = 0
    for finding in findings:
        desc = _description(finding)
        for marker in SPECULATION_MARKERS:
            total += desc.count(marker)
    return total


def speculation_marker_frequency(findings: list[dict]) -> float:
    """Fraction of findings containing at least one speculation marker.

    Returns 0.0 for an empty findings list.
    """
    if not findings:
        return 0.0
    count = 0
    for finding in findings:
        desc = _description(finding)
        if any(marker in desc for marker in SPECULATION_MARKERS):
            count += 1
    return count / len(findings)
