#!/usr/bin/env bash
# tests/hooks/test-write-test-status.sh
# Tests for write-test-status.sh helper script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/write-test-status.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo ""
echo "=== Test: write-test-status.sh ==="

# ============================================================
# Group 1: Exit code 0 → writes PASSED
# ============================================================
echo ""
echo "--- Group 1: PASSED on exit 0 ---"
_dir1=$(mktemp -d)
ARTIFACTS_DIR="$_dir1" bash "$SCRIPT" "test-unit-only" "0"
content=$(cat "$_dir1/test-status/test-unit-only.status")
assert_eq "Exit 0 writes PASSED" "PASSED" "$content"
rm -rf "$_dir1"

# ============================================================
# Group 2: Non-zero exit code → writes FAILED
# ============================================================
echo ""
echo "--- Group 2: FAILED on non-zero exit ---"
_dir2=$(mktemp -d)
ARTIFACTS_DIR="$_dir2" bash "$SCRIPT" "test-e2e" "1"
content=$(cat "$_dir2/test-status/test-e2e.status")
assert_eq "Exit 1 writes FAILED" "FAILED" "$content"

ARTIFACTS_DIR="$_dir2" bash "$SCRIPT" "test-lint" "127"
content=$(cat "$_dir2/test-status/test-lint.status")
assert_eq "Exit 127 writes FAILED" "FAILED" "$content"
rm -rf "$_dir2"

# ============================================================
# Group 3: Creates test-status/ directory if needed
# ============================================================
echo ""
echo "--- Group 3: Creates test-status dir ---"
_dir3=$(mktemp -d)
# Ensure no test-status dir exists
rmdir "$_dir3/test-status" 2>/dev/null || true
ARTIFACTS_DIR="$_dir3" bash "$SCRIPT" "test-unit-only" "0"
if [[ -d "$_dir3/test-status" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test-status directory not created" >&2
fi
rm -rf "$_dir3"

# ============================================================
# Group 4: Multiple targets produce separate files
# ============================================================
echo ""
echo "--- Group 4: Multiple targets → separate files ---"
_dir4=$(mktemp -d)
ARTIFACTS_DIR="$_dir4" bash "$SCRIPT" "test-unit-only" "0"
ARTIFACTS_DIR="$_dir4" bash "$SCRIPT" "test-e2e" "1"
ARTIFACTS_DIR="$_dir4" bash "$SCRIPT" "test-integration" "0"
ARTIFACTS_DIR="$_dir4" bash "$SCRIPT" "test-visual" "0"

assert_eq "unit file exists and PASSED" "PASSED" "$(cat "$_dir4/test-status/test-unit-only.status")"
assert_eq "e2e file exists and FAILED" "FAILED" "$(cat "$_dir4/test-status/test-e2e.status")"
assert_eq "integration file exists and PASSED" "PASSED" "$(cat "$_dir4/test-status/test-integration.status")"
assert_eq "visual file exists and PASSED" "PASSED" "$(cat "$_dir4/test-status/test-visual.status")"

file_count=$(ls "$_dir4/test-status/"*.status 2>/dev/null | wc -l | tr -d ' ')
assert_eq "4 separate status files" "4" "$file_count"
rm -rf "$_dir4"

# ============================================================
# Group 5: Backward-compatible wrapper works
# ============================================================
echo ""
echo "--- Group 5: Exec wrapper ---"
_dir5=$(mktemp -d)
WRAPPER="$DSO_PLUGIN_DIR/scripts/write-test-status.sh"
if [[ -x "$WRAPPER" ]]; then
    ARTIFACTS_DIR="$_dir5" bash "$WRAPPER" "test-unit-only" "0"
    content=$(cat "$_dir5/test-status/test-unit-only.status")
    assert_eq "Exec wrapper works" "PASSED" "$content"
else
    (( ++FAIL ))
    echo "FAIL: Wrapper not executable at $WRAPPER" >&2
fi
rm -rf "$_dir5"

print_summary
