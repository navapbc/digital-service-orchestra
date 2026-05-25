"""Banned-word matching for gov-copy artifacts."""
import re


def find_banned_words(text: str, banned_set: set[str]) -> list[str]:
    """Return banned words found in text, case-insensitive, preserving first-occurrence order, lowercased."""
    if not banned_set:
        return []
    lowered_banned = {w.lower() for w in banned_set}
    found = []
    seen = set()
    for match in re.finditer(r"\b[\w'-]+\b", text):
        word_lower = match.group().lower()
        if word_lower in lowered_banned and word_lower not in seen:
            found.append(word_lower)
            seen.add(word_lower)
    return found
