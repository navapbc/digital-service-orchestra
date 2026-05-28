#!/usr/bin/env bash
# update-required-checks-manifest.sh
# Adds required check-context names to .github/required-checks.txt when absent.
# Idempotent — no-op if all entries are already present.
# Sorts and deduplicates non-comment, non-blank lines while preserving comment
# and blank lines at the top of the file.
#
# Usage: update-required-checks-manifest.sh [--checks-file <path>]
#
# Exit codes:
#   0 — success (entries added or already present)
#   1 — error (file not found, validation failure)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"

# Entries that this script is responsible for ensuring are present in the
# main-branch manifest (.github/required-checks.txt).
#
# review-sub-pr is intentionally NOT in this list: it fires only on PRs whose
# base targets a sub-PR branch pattern, so requiring it on the main-branch
# ruleset would deadlock every PR to main. Enforcement of review-sub-pr lives
# on the sub-PR ruleset (16961402), populated by provision-ruleset.sh from
# the sub-PR branch-patterns source-of-truth file (config/sub-pr-branch-patterns.txt).
REQUIRED_ENTRIES=(
    "merge-pipeline-checks"
)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --checks-file)
            CHECKS_FILE="${2:-}"
            shift 2
            ;;
        --checks-file=*)
            CHECKS_FILE="${1#--checks-file=}"
            shift
            ;;
        -h|--help)
            echo "Usage: update-required-checks-manifest.sh [--checks-file <path>]"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "$CHECKS_FILE" ]]; then
    echo "Error: checks file not found: $CHECKS_FILE" >&2
    exit 1
fi

# Determine which entries are missing
MISSING=()
for entry in "${REQUIRED_ENTRIES[@]}"; do
    if ! grep -qxF "$entry" "$CHECKS_FILE" 2>/dev/null; then
        MISSING+=("$entry")
    fi
done

# If nothing is missing, we are done (idempotent no-op)
if [[ ${#MISSING[@]} -eq 0 ]]; then
    exit 0
fi

# Append missing entries to the file
for entry in "${MISSING[@]}"; do
    printf '%s\n' "$entry" >> "$CHECKS_FILE"
done

exit 0
