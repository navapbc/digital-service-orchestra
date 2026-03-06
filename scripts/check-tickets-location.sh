#!/usr/bin/env bash
# check-tickets-location.sh — Pre-commit hook to enforce single .tickets/ directory
#
# The authoritative .tickets/ directory lives at the repository root.
# This hook fails if any staged file places ticket data in a nested .tickets/
# directory (e.g., app/.tickets/, src/.tickets/).
#
# Works in both worktrees and main repo (uses git-relative paths from staging area).

set -euo pipefail

# Get all staged files that contain ".tickets/" in their path
STAGED_TICKET_FILES=$(git diff --cached --name-only 2>/dev/null | grep '\.tickets/' || true)

if [[ -z "$STAGED_TICKET_FILES" ]]; then
    exit 0  # No ticket files staged
fi

EXIT_CODE=0
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    # Authoritative path: starts with ".tickets/" (repo root)
    # Reject anything where .tickets/ appears after a leading directory
    if [[ "$file" != .tickets/* ]]; then
        echo "ERROR: .tickets/ directory must only exist at the repository root." >&2
        echo "  Rejected: $file" >&2
        echo "  Expected: .tickets/$(basename "$file")" >&2
        echo "" >&2
        echo "  The authoritative ticket store is <repo-root>/.tickets/." >&2
        echo "  Move this file to .tickets/ or remove it from the commit." >&2
        EXIT_CODE=1
    fi
done <<< "$STAGED_TICKET_FILES"

exit $EXIT_CODE
