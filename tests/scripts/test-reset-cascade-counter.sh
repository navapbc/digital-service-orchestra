#!/usr/bin/env bash
# tests/scripts/test-reset-cascade-counter.sh
# Unit tests for plugins/dso/scripts/fix-cascade-recovery/reset-cascade-counter.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/fix-cascade-recovery/reset-cascade-counter.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reset-cascade-counter.sh ==="

# ── test_script_exists ────────────────────────────────────────────────────────
echo "--- test_script_exists ---"
_snapshot_fail
script_check="missing_or_not_executable"
[[ -x "$RESET_SCRIPT" ]] && script_check="ok"
assert_eq "test_script_exists: script is executable" "ok" "$script_check"
assert_pass_if_clean "test_script_exists"

# ── test_creates_counter_file_with_zero ───────────────────────────────────────
echo "--- test_creates_counter_file_with_zero ---"
_snapshot_fail
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST" "/tmp/claude-cascade-${WT_HASH:-none}" 2>/dev/null || true' EXIT

cd "$TMPDIR_TEST" || exit 1
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
echo "x" > x.txt && git add x.txt && git commit -q -m "init"

# Compute hash first (before invoking the script) using the same algorithm
WT_ROOT=$(git rev-parse --show-toplevel)
if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$WT_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$WT_ROOT" | md5sum | cut -d' ' -f1)
else
    WT_HASH=$(echo -n "$WT_ROOT" | tr '/' '_')
fi
COUNTER_FILE="/tmp/claude-cascade-${WT_HASH}/counter"

bash "$RESET_SCRIPT" 2>/dev/null

counter_value=""
if [[ -f "$COUNTER_FILE" ]]; then
    counter_value=$(cat "$COUNTER_FILE")
fi
assert_eq "test_creates_counter_file_with_zero: counter contains 0" "0" "$counter_value"
assert_pass_if_clean "test_creates_counter_file_with_zero"

# ── test_removes_last_error_hash ───────────────────────────────────────────────
echo "--- test_removes_last_error_hash ---"
_snapshot_fail
HASH_FILE="/tmp/claude-cascade-${WT_HASH}/last-error-hash"
echo "old-hash" > "$HASH_FILE"

bash "$RESET_SCRIPT" 2>/dev/null

hash_exists="yes"
[[ ! -f "$HASH_FILE" ]] && hash_exists="no"
assert_eq "test_removes_last_error_hash: last-error-hash removed" "no" "$hash_exists"
assert_pass_if_clean "test_removes_last_error_hash"

# ── test_no_op_outside_git ────────────────────────────────────────────────────
echo "--- test_no_op_outside_git ---"
_snapshot_fail
OUTSIDE_DIR=$(mktemp -d)
nongit_exit=0
(cd "$OUTSIDE_DIR" && bash "$RESET_SCRIPT" 2>/dev/null) || nongit_exit=$?
rm -rf "$OUTSIDE_DIR"
assert_eq "test_no_op_outside_git: exits 0 outside git repo" "0" "$nongit_exit"
assert_pass_if_clean "test_no_op_outside_git"

cd "$REPO_ROOT" || exit 1
print_summary
