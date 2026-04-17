#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-locking.sh
# Tests for _is_lock_stale(), _acquire_lock(), _release_lock() in scripts/merge-to-main.sh
#
# Tests:
#   1. test_is_lock_stale_returns_true_for_dead_pid — dead PID means lock is stale
#   2. test_is_lock_stale_returns_false_for_live_matching_pid — live PID + matching command = valid lock
#   3. test_is_lock_stale_returns_true_for_pid_recycled_command_mismatch — live PID + wrong command = stale
#   4. test_is_lock_stale_returns_true_for_missing_lock_file — absent lock file = stale
#   5. test_acquire_lock_creates_lock_file_with_pid — acquire creates lock with PID|merge-to-main
#   6. test_acquire_lock_fails_when_lock_exists — acquire returns 1 if lock already held
#   7. test_release_lock_removes_file_when_owner — release removes lock when PID matches
#   8. test_release_lock_noop_when_not_owner — release no-ops when PID does not match
#  14. test_concurrent_merge_second_waits_then_succeeds — second session waits for first, then acquires
#  15. test_dead_lock_holder_lock_broken_and_acquired — stale lock broken and re-acquired by current session
#
# Usage: bash tests/scripts/test-merge-to-main-locking.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/merge-state.sh"

MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

echo "=== test-merge-to-main-locking.sh ==="

# --- Helper: extract _is_lock_stale function from merge-to-main.sh and source it ---
# We extract the function so we can test it in isolation without running the
# full merge-to-main.sh (which has side effects like cd, git checks, etc.)
_TEST_TMP=$(mktemp -d)
trap 'rm -rf "$_TEST_TMP"' EXIT

# Extract lock-related function definitions from the script
# Use sed to pull from function declaration to the closing brace
_extract_to_lock_funcs() {
    local fn_pat="$1" dest="$2"
    local _body
    _body=$(sed -n "/${fn_pat}/,/^}/p" "$MERGE_SCRIPT")
    if [[ -z "$_body" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _body=$(sed -n "/${fn_pat}/,/^}/p" "$MERGE_HELPERS_LIB")
    fi
    echo "$_body" >> "$dest"
}
_extract_to_lock_funcs '_is_lock_stale()' "$_TEST_TMP/lock_funcs.sh"
_extract_to_lock_funcs '_acquire_lock()' "$_TEST_TMP/lock_funcs.sh"
_extract_to_lock_funcs '_release_lock()' "$_TEST_TMP/lock_funcs.sh"
_extract_to_lock_funcs '_wait_for_lock()' "$_TEST_TMP/lock_funcs.sh"
_extract_to_lock_funcs '_cleanup_stale_git_state()' "$_TEST_TMP/lock_funcs.sh"

# Source the extracted functions
source "$_TEST_TMP/lock_funcs.sh"

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
# Test 5: test_acquire_lock_creates_lock_file_with_pid
# Acquiring a lock should create a file containing PID|merge-to-main.
# =============================================================================
echo ""
echo "--- acquire lock creates file with PID ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_acquire.lock"
rm -f "$_LOCK_FILE"

_acquire_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_acquire_lock_creates_lock_file_with_pid: returns 0" "0" "$_RC"

# File must exist
if [[ -f "$_LOCK_FILE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_acquire_lock_creates_lock_file_with_pid: lock file not created" >&2
fi

# Content must be PID|merge-to-main
_LOCK_CONTENT=$(cat "$_LOCK_FILE")
assert_eq "test_acquire_lock_creates_lock_file_with_pid: content" "$$|merge-to-main" "$_LOCK_CONTENT"

assert_pass_if_clean "acquire lock creates file with PID"

# =============================================================================
# Test 6: test_acquire_lock_fails_when_lock_exists
# Acquiring a lock when a valid lock already exists should return 1.
# =============================================================================
echo ""
echo "--- acquire lock fails when lock exists ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_acquire_exists.lock"
# Create a lock held by current process (valid lock — not stale)
_MY_CMD=$(ps -p $$ -o comm= 2>/dev/null || echo "bash")
echo "$$|${_MY_CMD}" > "$_LOCK_FILE"

_acquire_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_acquire_lock_fails_when_lock_exists: returns 1" "1" "$_RC"

# Original lock content should be preserved (not overwritten)
_LOCK_CONTENT=$(cat "$_LOCK_FILE")
assert_eq "test_acquire_lock_fails_when_lock_exists: content unchanged" "$$|${_MY_CMD}" "$_LOCK_CONTENT"

assert_pass_if_clean "acquire lock fails when lock exists"

# =============================================================================
# Test 7: test_release_lock_removes_file_when_owner
# Releasing a lock owned by current PID should remove the file.
# =============================================================================
echo ""
echo "--- release lock removes file when owner ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_release_owner.lock"
echo "$$|merge-to-main" > "$_LOCK_FILE"

_release_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_release_lock_removes_file_when_owner: returns 0" "0" "$_RC"

# File must be gone
if [[ ! -f "$_LOCK_FILE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_release_lock_removes_file_when_owner: lock file still exists" >&2
fi

assert_pass_if_clean "release lock removes file when owner"

# =============================================================================
# Test 8: test_release_lock_noop_when_not_owner
# Releasing a lock owned by a different PID should leave it in place.
# =============================================================================
echo ""
echo "--- release lock noop when not owner ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_release_not_owner.lock"
echo "999999999|merge-to-main" > "$_LOCK_FILE"

_release_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_release_lock_noop_when_not_owner: returns 1" "1" "$_RC"

# File must still exist
if [[ -f "$_LOCK_FILE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_release_lock_noop_when_not_owner: lock file was removed" >&2
fi

assert_pass_if_clean "release lock noop when not owner"

# =============================================================================
# Test 9: test_wait_for_lock_times_out_after_ceiling
# A held lock that never releases should cause _wait_for_lock to time out.
# =============================================================================
echo ""
echo "--- wait_for_lock times out after ceiling ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_wait_timeout.lock"
# Write a lock held by current PID with matching command (valid, non-stale lock)
_MY_CMD=$(ps -p $$ -o comm= 2>/dev/null || echo "bash")
echo "$$|${_MY_CMD}" > "$_LOCK_FILE"

# Override ceiling to 3 seconds for test speed
LOCK_WAIT_CEILING=3 _wait_for_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_wait_for_lock_times_out_after_ceiling: returns non-zero" "1" "$_RC"

assert_pass_if_clean "wait_for_lock times out after ceiling"

# =============================================================================
# Test 10: test_wait_for_lock_breaks_stale_lock_and_acquires
# A stale lock (dead PID + wrong command) should be broken and lock acquired.
# =============================================================================
echo ""
echo "--- wait_for_lock breaks stale lock and acquires ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_wait_stale.lock"
# Write a lock with a dead PID and wrong command
echo "999999999|some-dead-process" > "$_LOCK_FILE"

_wait_for_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_wait_for_lock_breaks_stale_lock_and_acquires: returns 0" "0" "$_RC"

# Lock file should now contain current PID
_LOCK_CONTENT=$(cat "$_LOCK_FILE")
assert_eq "test_wait_for_lock_breaks_stale_lock_and_acquires: content" "$$|merge-to-main" "$_LOCK_CONTENT"

assert_pass_if_clean "wait_for_lock breaks stale lock and acquires"

# =============================================================================
# Test 11: test_wait_for_lock_acquires_immediately_when_no_lock
# No pre-existing lock file should result in immediate acquisition.
# =============================================================================
echo ""
echo "--- wait_for_lock acquires immediately when no lock ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_wait_no_lock.lock"
rm -f "$_LOCK_FILE"

_wait_for_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_wait_for_lock_acquires_immediately_when_no_lock: returns 0" "0" "$_RC"

# Lock file should exist with current PID
if [[ -f "$_LOCK_FILE" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_wait_for_lock_acquires_immediately_when_no_lock: lock file not created" >&2
fi

_LOCK_CONTENT=$(cat "$_LOCK_FILE")
assert_eq "test_wait_for_lock_acquires_immediately_when_no_lock: content" "$$|merge-to-main" "$_LOCK_CONTENT"

assert_pass_if_clean "wait_for_lock acquires immediately when no lock"

# =============================================================================
# Test 12: test_rebase_state_cleaned_on_main_entry
# A stale REBASE_HEAD in .git/ should be cleaned up by _cleanup_stale_git_state.
# =============================================================================
echo ""
echo "--- rebase state cleaned on main entry ---"
_snapshot_fail

# Create a temporary git repo to simulate stale rebase state
_REBASE_REPO="$_TEST_TMP/rebase_test_repo"
git init -b main "$_REBASE_REPO" --quiet
# Create an initial commit so the repo is valid
git -C "$_REBASE_REPO" commit --allow-empty -m "initial" --quiet
# Simulate stale rebase state by creating REBASE_HEAD
_GIT_DIR=$(git -C "$_REBASE_REPO" rev-parse --git-dir)
# Make _GIT_DIR absolute if relative
if [[ "$_GIT_DIR" != /* ]]; then
    _GIT_DIR="$_REBASE_REPO/$_GIT_DIR"
fi
touch "$_GIT_DIR/REBASE_HEAD"

# Verify REBASE_HEAD exists before cleanup
if [[ -f "$_GIT_DIR/REBASE_HEAD" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_rebase_state_cleaned_on_main_entry: REBASE_HEAD not created" >&2
fi

# Call _cleanup_stale_git_state — should remove stale rebase state
_cleanup_stale_git_state "$_REBASE_REPO"

# REBASE_HEAD should be gone after cleanup
if [[ ! -f "$_GIT_DIR/REBASE_HEAD" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_rebase_state_cleaned_on_main_entry: REBASE_HEAD still present after cleanup" >&2
fi

assert_pass_if_clean "rebase state cleaned on main entry"

# =============================================================================
# Test 13: test_cleanup_stale_git_state_noop_when_clean
# _cleanup_stale_git_state should be a no-op when no stale state exists.
# =============================================================================
echo ""
echo "--- cleanup stale git state noop when clean ---"
_snapshot_fail

_CLEAN_REPO="$_TEST_TMP/clean_test_repo"
git init -b main "$_CLEAN_REPO" --quiet
git -C "$_CLEAN_REPO" commit --allow-empty -m "initial" --quiet

# Call _cleanup_stale_git_state — should not error
_cleanup_stale_git_state "$_CLEAN_REPO"
_RC=$?
assert_eq "test_cleanup_stale_git_state_noop_when_clean: returns 0" "0" "$_RC"

assert_pass_if_clean "cleanup stale git state noop when clean"

# =============================================================================
# Test 14: test_concurrent_merge_second_waits_then_succeeds
# A second session waits while the first holds the lock, then succeeds after
# the first releases. Uses real background processes.
# =============================================================================
echo ""
echo "--- concurrent merge: second waits then succeeds ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_concurrent.lock"
rm -f "$_LOCK_FILE"

# Simulate first session holding the lock: write lock with current PID and matching command
_MY_CMD=$(ps -p $$ -o comm= 2>/dev/null || echo "bash")
echo "$$|${_MY_CMD}" > "$_LOCK_FILE"

# Start background job that waits to acquire the lock
_BG_RESULT="$_TEST_TMP/concurrent_result"
rm -f "$_BG_RESULT"
(
    # Source the extracted functions in the subshell
    source "$_TEST_TMP/lock_funcs.sh"
    LOCK_WAIT_CEILING=10 _wait_for_lock "$_LOCK_FILE"
    echo $? > "$_BG_RESULT"
) &
_BG_PID=$!

# Let the background job start and attempt to acquire (it should be waiting)
sleep 1

# Release the lock by removing the file (simulating first session completing)
rm -f "$_LOCK_FILE"

# Wait for background job to finish
wait "$_BG_PID" 2>/dev/null

# Read result: background job should have acquired the lock (exit 0)
if [[ -f "$_BG_RESULT" ]]; then
    _RC=$(cat "$_BG_RESULT")
    assert_eq "test_concurrent_merge_second_waits_then_succeeds: exit code" "0" "$_RC"
else
    (( ++FAIL ))
    echo "FAIL: test_concurrent_merge_second_waits_then_succeeds: result file not created" >&2
fi

# Lock file should exist and be owned by the background job's PID (or already released).
# Since the background job exited, the lock file may still exist with its PID.
# We just verify the wait succeeded (exit 0 above).

assert_pass_if_clean "concurrent merge: second waits then succeeds"

# =============================================================================
# Test 15: test_dead_lock_holder_lock_broken_and_acquired
# A session recovers from a dead lock holder by detecting the stale lock,
# breaking it, and acquiring the lock for itself.
# =============================================================================
echo ""
echo "--- dead lock holder: lock broken and acquired ---"
_snapshot_fail

_LOCK_FILE="$_TEST_TMP/test_dead_holder.lock"
rm -f "$_LOCK_FILE"

# Find a guaranteed-dead PID: start from a high number and verify it's not alive
_DEAD_PID=4000000
while kill -0 "$_DEAD_PID" 2>/dev/null; do
    _DEAD_PID=$(( _DEAD_PID + 1 ))
done

# Write lock file with the dead PID
echo "${_DEAD_PID}|merge-to-main" > "$_LOCK_FILE"

# _wait_for_lock should detect the stale lock, break it, and acquire immediately
_wait_for_lock "$_LOCK_FILE"
_RC=$?
assert_eq "test_dead_lock_holder_lock_broken_and_acquired: returns 0" "0" "$_RC"

# Lock file should now contain current PID ($$)
_LOCK_CONTENT=$(cat "$_LOCK_FILE")
assert_eq "test_dead_lock_holder_lock_broken_and_acquired: PID is $$" "$$|merge-to-main" "$_LOCK_CONTENT"

assert_pass_if_clean "dead lock holder: lock broken and acquired"

# =============================================================================
# Summary
# =============================================================================
print_summary
