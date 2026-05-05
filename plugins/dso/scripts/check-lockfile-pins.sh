#!/usr/bin/env bash
# check-lockfile-pins.sh — Scan lockfile for loose version operators.
# Usage: bash check-lockfile-pins.sh [lockfile-path]
# Exits 1 if any ~=, >=, <=, !=, >, < operator found; 0 if all pins use ==.
set -euo pipefail
LOCK="${1:-$(dirname "${BASH_SOURCE[0]}")/requirements.lock}"
if [[ ! -f "$LOCK" ]]; then
    echo "ERROR: lockfile not found: $LOCK" >&2; exit 1
fi
# Match package lines (start with letter) that have a loose operator before a digit
if grep -qE '^[[:space:]]*[a-zA-Z][a-zA-Z0-9_.+-]*[[:space:]]*(>=|<=|~=|!=|>|<)[0-9]' "$LOCK"; then
    grep -E '^[[:space:]]*[a-zA-Z][a-zA-Z0-9_.+-]*[[:space:]]*(>=|<=|~=|!=|>|<)[0-9]' "$LOCK" >&2
    echo "ERROR: loose pins found in $LOCK" >&2; exit 1
fi
echo "OK: all pins in $LOCK are exact (== only)"
