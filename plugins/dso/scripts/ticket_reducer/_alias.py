"""Compute deterministic adjective-noun-noun aliases from ticket IDs.

Used as a read-time fallback for tickets created before the alias feature
shipped (their CREATE event has no `data.alias`). Mirrors the algorithm in
`ticket-alias-compute.py` so legacy tickets surface the same alias they
would have been assigned at creation.
"""

from __future__ import annotations

import os

_WORDS_CACHE: tuple[list[str], list[str]] | None = None


def _wordlist_path() -> str:
    """Resolve the bundled wordlist path. Honours TICKET_WORDLIST_PATH override."""
    env = os.environ.get("TICKET_WORDLIST_PATH")
    if env:
        return env
    # This module lives at <plugin_root>/scripts/ticket_reducer/_alias.py;
    # the wordlist is at <plugin_root>/resources/ticket-wordlist.txt.
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "resources", "ticket-wordlist.txt"))


def _load() -> tuple[list[str], list[str]]:
    global _WORDS_CACHE
    if _WORDS_CACHE is not None:
        return _WORDS_CACHE
    adjs: list[str] = []
    nouns: list[str] = []
    section = "adj"
    try:
        with open(_wordlist_path(), encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if line == "# NOUNS":
                    section = "noun"
                    continue
                if line.startswith("#") or not line.strip():
                    continue
                (adjs if section == "adj" else nouns).append(line.strip())
    except OSError:
        pass
    _WORDS_CACHE = (adjs, nouns)
    return _WORDS_CACHE


def compute_alias(ticket_id: str) -> str | None:
    """Return the alias for `ticket_id`, or None if the wordlist is unavailable.

    Returns the same string `ticket-alias-compute.py` would print for the same
    ticket_id and wordlist. Falls back to the first 8 hex chars (no dash) when
    the wordlist is empty/missing — matching the shell-side fallback.
    """
    hex_id = ticket_id.replace("-", "")
    if len(hex_id) < 8:
        return None
    adjs, nouns = _load()
    if not adjs or not nouns:
        return hex_id[: min(len(hex_id), 8)]
    try:
        adj = adjs[int(hex_id[0:4], 16) % len(adjs)]
        n1 = nouns[int(hex_id[4:8], 16) % len(nouns)]
    except ValueError:
        return None
    # Legacy 8-hex tickets get a 2-word alias (adj-noun); 16-hex get adj-noun-noun.
    if len(hex_id) >= 12:
        try:
            n2 = nouns[int(hex_id[8:12], 16) % len(nouns)]
        except ValueError:
            return f"{adj}-{n1}"
        return f"{adj}-{n1}-{n2}"
    return f"{adj}-{n1}"
