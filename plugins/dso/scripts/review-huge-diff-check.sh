#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Read threshold from config (default 20)
# Append SCRIPT_DIR to PATH so read-config.sh is found; existing PATH entries (e.g. test mocks) take precedence
threshold=$(PATH="$PATH:$SCRIPT_DIR" read-config.sh review.huge_diff_file_threshold 2>/dev/null || true)
threshold=${threshold:-20}

# Validate threshold
if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [[ "$threshold" -le 0 ]]; then
  echo "review-huge-diff-check: invalid review.huge_diff_file_threshold: '$threshold' (must be a positive integer)" >&2
  exit 1
fi

# Count changed files, excluding .test-index
file_count=$(git diff --name-only HEAD 2>/dev/null | grep -v '^\.test-index$' | wc -l | tr -d ' ')

if [[ "$file_count" -ge "$threshold" ]]; then
  exit 2
fi
exit 0
