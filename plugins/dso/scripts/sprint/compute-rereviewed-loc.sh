#!/usr/bin/env bash
# compute-rereviewed-loc.sh — compute re-review ratio for a sprint
# Usage: compute-rereviewed-loc.sh <epic-id> <review-log-dir>
#
# Arguments:
#   epic-id        — epic being validated
#   review-log-dir — directory containing review log files
#
# Output:
#   re-review ratio: N  (where N is integer 0-100 percentage)
#
# Exit codes:
#   0 — ratio < 50 (acceptable)
#   1 — ratio >= 50 (threshold exceeded) OR error

set -euo pipefail

EPIC_ID="${1:-}"
REVIEW_LOG_DIR="${2:-}"

if [[ -z "$EPIC_ID" || -z "$REVIEW_LOG_DIR" ]]; then
    echo "Usage: $(basename "$0") <epic-id> <review-log-dir>" >&2
    exit 1
fi

if [[ ! -d "$REVIEW_LOG_DIR" ]]; then
    echo "Error: review-log-dir not found: $REVIEW_LOG_DIR" >&2
    exit 1
fi

SUMMARY_FILE="$REVIEW_LOG_DIR/review-summary.json"

total_loc=0
rereviewed_loc=0

if [[ -f "$SUMMARY_FILE" ]]; then
    # Parse JSON fields using grep+sed (no jq dependency)
    total_loc=$(grep -oE '"total_loc_reviewed":[0-9]+' "$SUMMARY_FILE" | grep -oE '[0-9]+$' || echo "0")
    rereviewed_loc=$(grep -oE '"rereviewed_loc":[0-9]+' "$SUMMARY_FILE" | grep -oE '[0-9]+$' || echo "0")
fi

total_loc="${total_loc:-0}"
rereviewed_loc="${rereviewed_loc:-0}"

# Compute ratio (integer percentage)
if [[ "$total_loc" -eq 0 ]]; then
    ratio=0
else
    ratio=$(( rereviewed_loc * 100 / total_loc ))
fi

echo "re-review ratio: $ratio"

if [[ "$ratio" -ge 50 ]]; then
    exit 1
fi

exit 0
