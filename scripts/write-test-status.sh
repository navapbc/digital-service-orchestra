#!/usr/bin/env bash
set -euo pipefail
# scripts/write-test-status.sh
# Write test result status for the test-failure commit guard.
#
# Usage: write-test-status.sh <target-name> <exit-code>
#   target-name: e.g., test-unit-only, test-e2e, test-integration, test-visual
#   exit-code:   0 = PASSED, non-zero = FAILED
#
# Writes to $ARTIFACTS_DIR/test-status/<target-name>.status
# Creates the test-status/ directory if needed.
#
# The commit guard (hook_test_failure_guard) reads these files and blocks
# commits when any contains "FAILED" on the first line.

set -euo pipefail

TARGET="${1:-}"
EXIT_CODE="${2:-}"

if [[ -z "$TARGET" || -z "$EXIT_CODE" ]]; then
    echo "Usage: write-test-status.sh <target-name> <exit-code>" >&2
    exit 1
fi

# Resolve artifacts dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${SCRIPT_DIR%/scripts}"

# Source deps.sh for get_artifacts_dir
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

ARTIFACTS_DIR_RESOLVED="${ARTIFACTS_DIR:-$(get_artifacts_dir)}"
STATUS_DIR="$ARTIFACTS_DIR_RESOLVED/test-status"
mkdir -p "$STATUS_DIR"

if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "PASSED" > "$STATUS_DIR/${TARGET}.status"
else
    echo "FAILED" > "$STATUS_DIR/${TARGET}.status"
fi
