#!/usr/bin/env bash
set -euo pipefail
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# scripts/verify-review-diff.sh
# Validate that a review diff file matches the current working tree state.
# Used by the code-review sub-agent before reading the diff.
#
# Usage:
#   verify-review-diff.sh <diff-file-path>
#
# Exit codes:
#   0 = diff file matches current working tree (DIFF_VALID: yes)
#   1 = mismatch or file missing (DIFF_VALID: no ...)

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: verify-review-diff.sh <diff-file-path>" >&2
    exit 1
fi

DIFF_FILE="$1"

# Resolve CLAUDE_PLUGIN_ROOT with a fallback for worktree sessions where it may be unset.
# Export so compute-diff-hash.sh (a subprocess) inherits the resolved value.
export CLAUDE_PLUGIN_ROOT="${_PLUGIN_ROOT}"

# Check file exists
if [ ! -f "$DIFF_FILE" ]; then
    echo "DIFF_VALID: no (file not found: $DIFF_FILE)"
    exit 1
fi

# Check file is not empty
if [ ! -s "$DIFF_FILE" ]; then
    echo "DIFF_VALID: no (file is empty: $DIFF_FILE)"
    exit 1
fi

# Extract hash fragment from filename (e.g., review-diff-a1b2c3d4.txt or .patch -> a1b2c3d4)
filename=$(basename "$DIFF_FILE")
file_hash=$(echo "$filename" | sed -n 's/.*-\([0-9a-f]\{8,\}\)\.[a-z]*$/\1/p')

if [ -z "$file_hash" ]; then
    echo "DIFF_VALID: no (could not extract hash from filename: $filename)"
    exit 1
fi

# Compute current working tree hash
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
current_hash=$("${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh")
current_hash_short="${current_hash:0:8}"

# Compare using 8-char prefix of both hashes (filename may contain full 64-char hash)
file_hash_short="${file_hash:0:8}"
if [ "$file_hash_short" = "$current_hash_short" ]; then
    echo "DIFF_VALID: yes"
    exit 0
else
    echo "DIFF_VALID: no (file: $file_hash_short, current: $current_hash_short)"
    exit 1
fi
