"""Similarity helpers for analyze-tool-use."""

from __future__ import annotations


def char_similarity(a: str, b: str) -> float:
    """Return Jaccard-style character overlap ratio for short strings."""
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0

    # Use bigrams for a reasonable similarity approximation
    def bigrams(s: str) -> set[str]:
        return {s[i : i + 2] for i in range(len(s) - 1)}

    bg_a = bigrams(a)
    bg_b = bigrams(b)
    if not bg_a and not bg_b:
        return 1.0
    if not bg_a or not bg_b:
        return 0.0
    intersection = len(bg_a & bg_b)
    union = len(bg_a | bg_b)
    return intersection / union


def word_overlap(a: str, b: str) -> float:
    """Return fraction of words in a that also appear in b."""
    words_a = set(a.lower().split())
    words_b = set(b.lower().split())
    if not words_a:
        return 0.0
    return len(words_a & words_b) / len(words_a)
