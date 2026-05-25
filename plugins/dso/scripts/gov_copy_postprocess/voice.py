"""Active-voice detection via regex heuristic."""
import re

# be-verb + past-participle pattern
_PASSIVE_PATTERN = re.compile(
    r"\b(am|is|are|was|were|be|been|being)\b\s+\w*(ed|reviewed|submitted|done|seen|given|taken|made|written|broken)\b",
    re.IGNORECASE,
)


def is_active_voice(text: str) -> bool:
    """Return True if no passive construction (be-verb + past-participle) detected."""
    return not bool(_PASSIVE_PATTERN.search(text))
