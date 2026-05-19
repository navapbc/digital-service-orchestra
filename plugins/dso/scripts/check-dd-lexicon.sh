#!/usr/bin/env bash
# scripts/check-dd-lexicon.sh
# Check a done definition for precision vocabulary and compound requirements.
#
# Usage: echo "<done-definition-text>" | check-dd-lexicon.sh
# Exit codes:
#   0 = clean DD (no vague or compound terms detected)
#   1 = violation found; outputs JSON: {"type":"compound|vague","matched_text":"...","dd":"..."}
#
# Compound detection:
#   - Uppercase ' AND ' always signals a compound requirement
#
# Vague vocabulary:
#   properly, correctly, appropriately, well, good, better, clean, adequate,
#   reasonable, appropriate, suitable, should

set -euo pipefail

# Read DD from stdin
_DD=$(cat)

# ── Compound detection ────────────────────────────────────────────────────────

# Uppercase ' AND ' is always a compound conjunction
if echo "$_DD" | grep -qF ' AND '; then
    _MATCHED=$(echo "$_DD" | grep -oF ' AND ' | head -1 | tr -d ' ')
    printf '{"type":"compound","matched_text":"%s","dd":"%s"}\n' \
        "AND" \
        "$(echo "$_DD" | sed 's/"/\\"/g')"
    exit 1
fi

# ── Vague vocabulary detection ────────────────────────────────────────────────

# List of vague words/phrases to detect (word-boundary aware via grep -w)
_VAGUE_WORDS=(
    "properly"
    "correctly"
    "appropriately"
    "well"
    "adequate"
    "reasonable"
    "appropriate"
    "suitable"
    "should"
)

for _WORD in "${_VAGUE_WORDS[@]}"; do
    if echo "$_DD" | grep -qiw "$_WORD"; then
        _MATCHED=$(echo "$_DD" | grep -iow "$_WORD" | head -1)
        printf '{"type":"vague","matched_text":"%s","dd":"%s"}\n' \
            "$_MATCHED" \
            "$(echo "$_DD" | sed 's/"/\\"/g')"
        exit 1
    fi
done

# ── Clean ─────────────────────────────────────────────────────────────────────

exit 0
