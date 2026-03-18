#!/usr/bin/env bash
# tests/plugin/test-verify-review-diff.sh
# Tests for verify-review-diff.sh — validates review diff hash verification.
#
# Manual run:
#   bash tests/plugin/test-verify-review-diff.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
VERIFY_SCRIPT="$DSO_PLUGIN_DIR/scripts/verify-review-diff.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== verify-review-diff.sh tests ==="
echo ""

# ---------------------------------------------------------------------------
# Prerequisite: script exists and is executable
# ---------------------------------------------------------------------------
echo "--- prerequisite: script exists and is executable ---"

assert_eq "verify-review-diff.sh exists" "true" \
    "$(test -f "$VERIFY_SCRIPT" && echo true || echo false)"

assert_eq "verify-review-diff.sh is executable" "true" \
    "$(test -x "$VERIFY_SCRIPT" && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test A: No arguments — should print usage and exit 1
# ---------------------------------------------------------------------------
echo ""
echo "--- Test A: no arguments prints usage and exits 1 ---"

exit_a=0
output_a=$(bash "$VERIFY_SCRIPT" 2>&1) || exit_a=$?
assert_eq "no-args exits non-zero" "1" "$exit_a"
assert_contains "no-args prints usage" "Usage:" "$output_a"

# ---------------------------------------------------------------------------
# Test B: Non-existent file — should report file not found
# ---------------------------------------------------------------------------
echo ""
echo "--- Test B: non-existent file ---"

exit_b=0
output_b=$(bash "$VERIFY_SCRIPT" "/tmp/nonexistent-review-diff-abc12345.txt" 2>&1) || exit_b=$?
assert_eq "missing-file exits non-zero" "1" "$exit_b"
assert_contains "missing-file reports not found" "DIFF_VALID: no" "$output_b"
assert_contains "missing-file mentions file not found" "file not found" "$output_b"

# ---------------------------------------------------------------------------
# Test C: Empty file — should report file is empty
# ---------------------------------------------------------------------------
echo ""
echo "--- Test C: empty file ---"

TMPDIR_C=$(mktemp -d)
trap 'rm -rf "$TMPDIR_C"' EXIT
EMPTY_FILE="$TMPDIR_C/review-diff-abc12345.txt"
touch "$EMPTY_FILE"

exit_c=0
output_c=$(bash "$VERIFY_SCRIPT" "$EMPTY_FILE" 2>&1) || exit_c=$?
assert_eq "empty-file exits non-zero" "1" "$exit_c"
assert_contains "empty-file reports empty" "file is empty" "$output_c"

# ---------------------------------------------------------------------------
# Test D: Filename without hash pattern — should report cannot extract hash
# ---------------------------------------------------------------------------
echo ""
echo "--- Test D: filename without hash pattern ---"

NO_HASH_FILE="$TMPDIR_C/review-diff-nohash.txt"
echo "some content" > "$NO_HASH_FILE"

exit_d=0
output_d=$(bash "$VERIFY_SCRIPT" "$NO_HASH_FILE" 2>&1) || exit_d=$?
assert_eq "no-hash exits non-zero" "1" "$exit_d"
assert_contains "no-hash reports cannot extract" "could not extract hash" "$output_d"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
