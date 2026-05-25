"""Active-voice detection via regex heuristic.

Matches `be-verb + past-participle` constructions. The regular-past pattern
requires at least 2 letters before `ed` (avoiding false positives on short
words like 'bed', 'red', 'ted', 'fed' — none of which are past participles).
Common irregular past participles are listed explicitly.
"""
import re

# be-verb + past-participle pattern.
# Regular past: at least 2 alphabetic characters preceding 'ed' (e.g. 'reviewed',
# 'submitted'), preventing false-match on 'bed' / 'red' / 'ted' / 'fed' / 'wed'.
# Irregulars: explicit list of forms frequently used in government UI copy.
_PASSIVE_PATTERN = re.compile(
    r"\b(am|is|are|was|were|be|been|being)\b\s+"
    r"(?:[a-z]{2,}ed|reviewed|submitted|done|seen|given|taken|made|written|broken|chosen|known|shown|paid|sent|kept|held|told|sold|brought|caught|found|left|lost|met|read|set|put|cut|hit|let|run)\b",
    re.IGNORECASE,
)


def is_active_voice(text: str) -> bool:
    """Return True if no passive construction (be-verb + past-participle) detected."""
    return not bool(_PASSIVE_PATTERN.search(text))
