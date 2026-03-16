#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-merge-to-main-locking.sh
# Tests for _is_lock_stale() in lockpick-workflow/scripts/merge-to-main.sh
#
# Tests:
#   1. test_is_lock_stale_returns_true_for_dead_pid — dead PID means lock is stale
#   2. test_is_lock_stale_returns_false_for_live_matching_pid — live PID + matching command = valid lock
#   3. test_is_lock_stale_returns_true_for_pid_recycled_command_mismatch — live PID + wrong command = stale
#   4. test_is_lock_stale_returns_true_for_missing_lock_file — absent lock file = stale
#
# Usage: bash lockpick-workflow/tests/scripts/test-merge-to-main-locking.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

MERGE_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/merge-to-main.sh"

echo "=== test-merge-to-main-locking.sh ==="

# --- Helper: extract _is_lock_stale function from merge-to-main.sh and source it ---
# We extract the function so we can test it in isolation without running the
# full merge-to-main.sh (which has side effects like cd, git checks, etc.)
_TEST_TMP=$(mktemp -d)
trap 'rm -rf "$_TEST_TMP"' EXIT

# Extract _is_lock_stale function definition from the script
# Use sed to pull from function declaration to the closing brace
sed -n '/_is_lock_stale()/,/^}/p' "$MERGE_SCRIPT" > "$_TEST_TMP/is_lock_stale_func.sh"

# Source the extracted function
source "$_TEST_TMP/is_lock_stale_func.sh"

# =============================================================================
# Test 1: test_is_lock_stale_returns_true_for_dead_pid
# A lock file with a PID that does not exist should be considered stale.
# =============================================================================
echo ""
echo "--- dead PID returns stale ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_dead_pid.lock"
# Use a PID that is guaranteed not to exist
echo "999999999|merge-to-main" > "$_LOCK_FILE"

_is_lock_stale "$_LOCK_FILE"
_RC=$?
assert_eq "test_is_lock_stale_returns_true_for_dead_pid" "0" "$_RC"

assert_pass_if_clean "dead PID lock is stale"

# =============================================================================
# Test 2: test_is_lock_stale_returns_false_for_live_matching_pid
# A lock file with the current PID and a matching command should be valid.
# =============================================================================
echo ""
echo "--- live matching PID returns not stale ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_live_pid.lock"
# Use current process PID — it is alive. Get the current command name.
_MY_CMD=$(ps -p $$ -o comm= 2>/dev/null || echo "bash")
echo "$$|${_MY_CMD}" > "$_LOCK_FILE"

_is_lock_stale "$_LOCK_FILE"
_RC=$?
assert_eq "test_is_lock_stale_returns_false_for_live_matching_pid" "1" "$_RC"

assert_pass_if_clean "live matching PID lock is not stale"

# =============================================================================
# Test 3: test_is_lock_stale_returns_true_for_pid_recycled_command_mismatch
# A lock file with the current PID but a wrong command name should be stale
# (PID was recycled to a different process).
# =============================================================================
echo ""
echo "--- PID recycled (command mismatch) returns stale ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_recycled_pid.lock"
# Use current PID but a command name that does not match
echo "$$|bash-unrelated-process-xyz" > "$_LOCK_FILE"

_is_lock_stale "$_LOCK_FILE"
_RC=$?
assert_eq "test_is_lock_stale_returns_true_for_pid_recycled_command_mismatch" "0" "$_RC"

assert_pass_if_clean "PID recycled lock is stale"

# =============================================================================
# Test 4: test_is_lock_stale_returns_true_for_missing_lock_file
# A non-existent lock file should be considered stale (absent = can acquire).
# =============================================================================
echo ""
echo "--- missing lock file returns stale ---"
_snapshot_fail

_is_lock_stale "$_TEST_TMP/nonexistent.lock"
_RC=$?
assert_eq "test_is_lock_stale_returns_true_for_missing_lock_file" "0" "$_RC"

assert_pass_if_clean "missing lock file is stale"

# =============================================================================
# Summary
# =============================================================================
print_summary
