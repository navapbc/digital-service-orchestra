"""Readability scoring for gov-copy artifacts."""
import textstat


def compute_fk_grade(text: str) -> float:
    """Return Flesch-Kincaid grade level. Deterministic delegate to textstat."""
    return textstat.flesch_kincaid_grade(text)
