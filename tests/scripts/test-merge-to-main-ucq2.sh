#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-merge-to-main-ucq2.sh
# Tests for _check_push_needed helper in merge-to-main.sh
#
# TDD tests:
#   1. test_check_push_needed_exists_as_function — _check_push_needed() defined in script
#   2. test_check_push_needed_git_fetch_called — function body contains 'git fetch origin'
#   3. test_check_push_needed_git_log_check — function body contains 'git log origin/main..HEAD'
#   4. test_check_push_needed_skip_message — function body contains 'Push skipped' message
#   5. test_check_push_needed_fetch_failure_returns_push_needed — fetch failure returns 0 (push needed)
#
# Usage: bash lockpick-workflow/tests/scripts/test-merge-to-main-ucq2.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/merge-to-main.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# =============================================================================
# Test 1: _check_push_needed function exists in merge-to-main.sh
# =============================================================================
HAS_FUNCTION=$(grep -c '_check_push_needed()' "$MERGE_SCRIPT" || true)
assert_ne "test_check_push_needed_exists_as_function" "0" "$HAS_FUNCTION"

# =============================================================================
# Test 2: Function body includes git fetch origin
# The function should fetch the latest remote state before checking.
# =============================================================================
FUNC_BODY=$(sed -n '/_check_push_needed()/,/^}/p' "$MERGE_SCRIPT")
HAS_FETCH=$(echo "$FUNC_BODY" | grep -c 'git fetch origin' || true)
assert_ne "test_check_push_needed_git_fetch_called" "0" "$HAS_FETCH"

# =============================================================================
# Test 3: Function body includes git log origin/main..HEAD check
# The function should check if there are commits ahead of origin/main.
# =============================================================================
HAS_LOG_CHECK=$(echo "$FUNC_BODY" | grep -c 'git log origin/main\.\.HEAD' || true)
assert_ne "test_check_push_needed_git_log_check" "0" "$HAS_LOG_CHECK"

# =============================================================================
# Test 4: Skip message present for already-pushed case
# When no push is needed, function should emit an informational message.
# =============================================================================
HAS_SKIP_MSG=$(echo "$FUNC_BODY" | grep -c 'Push skipped' || true)
assert_ne "test_check_push_needed_skip_message" "0" "$HAS_SKIP_MSG"

# =============================================================================
# Test 5: Fetch failure handling — returns 0 (push needed) on fetch error
# The function should not suppress a push just because fetch failed.
# =============================================================================
HAS_FETCH_GUARD=$(echo "$FUNC_BODY" | grep -cE 'git fetch.*\|\||if.*git fetch' || true)
assert_ne "test_check_push_needed_fetch_failure_returns_push_needed" "0" "$HAS_FETCH_GUARD"

# =============================================================================
# Test 6: _abort_stale_rebase function exists in merge-to-main.sh
# =============================================================================
HAS_ABORT_FUNC=$(grep -c '_abort_stale_rebase()' "$MERGE_SCRIPT" || true)
assert_ne "test_abort_stale_rebase_exists_as_function" "0" "$HAS_ABORT_FUNC"

# =============================================================================
# Test 7: _abort_stale_rebase checks for REBASE_HEAD
# The function should check for a stale rebase state file.
# =============================================================================
ABORT_FUNC_BODY=$(sed -n '/_abort_stale_rebase()/,/^}/p' "$MERGE_SCRIPT")
HAS_REBASE_HEAD=$(echo "$ABORT_FUNC_BODY" | grep -c 'REBASE_HEAD' || true)
assert_ne "test_abort_stale_rebase_checks_rebase_head" "0" "$HAS_REBASE_HEAD"

# =============================================================================
# Test 8: Pull conflict path emits CONFLICT_DATA with phase=pull_rebase
# When git pull --rebase fails, structured conflict data should be emitted.
# =============================================================================
HAS_PULL_CONFLICT_DATA=$(grep -c 'CONFLICT_DATA.*phase=pull_rebase' "$MERGE_SCRIPT" || true)
assert_ne "test_pull_conflict_emits_conflict_data" "0" "$HAS_PULL_CONFLICT_DATA"

# =============================================================================
# Test 9: Pull conflict path records conflict state via _set_phase_status
# The pull failure path should record conflict status in the state file.
# =============================================================================
# Extract the pull --rebase failure block (from 'git pull --rebase' to the next phase)
PULL_SECTION=$(sed -n '/git pull --rebase/,/OK: Pulled remote/p' "$MERGE_SCRIPT")
HAS_CONFLICT_STATE=$(echo "$PULL_SECTION" | grep -cE '_set_phase_status.*conflict|_set_phase_status.*pull_rebase' || true)
assert_ne "test_pull_conflict_records_conflict_state" "0" "$HAS_CONFLICT_STATE"

# =============================================================================
# Test 10: Push section calls _check_push_needed before retry_with_backoff git push
# The push phase should guard the retry_with_backoff push with _check_push_needed.
# =============================================================================
# Extract line numbers: _check_push_needed must appear BEFORE retry_with_backoff.*git push
PUSH_CHECK_LINE=$(grep -n '_check_push_needed' "$MERGE_SCRIPT" | grep -v '()' | grep -v '^#' | head -1 | cut -d: -f1)
PUSH_RETRY_LINE=$(grep -n 'retry_with_backoff.*git push' "$MERGE_SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$PUSH_CHECK_LINE" && -n "$PUSH_RETRY_LINE" && "$PUSH_CHECK_LINE" -lt "$PUSH_RETRY_LINE" ]]; then
    PUSH_ORDER_OK="yes"
else
    PUSH_ORDER_OK="no"
fi
assert_eq "test_push_section_calls_check_push_needed" "yes" "$PUSH_ORDER_OK"

# =============================================================================
# Test 11: Pull section calls _abort_stale_rebase before git pull --rebase
# The sync phase should clean up stale rebase state BEFORE attempting git pull --rebase.
# =============================================================================
# Extract line numbers within _phase_sync: _abort_stale_rebase must appear BEFORE git pull --rebase
# We need a call to _abort_stale_rebase that is BEFORE the git pull --rebase line (not just in the error handler)
PHASE_SYNC_BODY=$(sed -n '/_phase_sync()/,/^}/p' "$MERGE_SCRIPT")
# Get line numbers within the phase body
ABORT_BEFORE_PULL_LINE=$(echo "$PHASE_SYNC_BODY" | grep -n '_abort_stale_rebase' | head -1 | cut -d: -f1)
PULL_REBASE_LINE=$(echo "$PHASE_SYNC_BODY" | grep -n 'git pull --rebase' | head -1 | cut -d: -f1)
if [[ -n "$ABORT_BEFORE_PULL_LINE" && -n "$PULL_REBASE_LINE" && "$ABORT_BEFORE_PULL_LINE" -lt "$PULL_REBASE_LINE" ]]; then
    ABORT_ORDER_OK="yes"
else
    ABORT_ORDER_OK="no"
fi
assert_eq "test_pull_section_calls_abort_stale_rebase_on_entry" "yes" "$ABORT_ORDER_OK"

# =============================================================================
# Test 12: bash -n syntax check passes after all changes
# =============================================================================
if bash -n "$MERGE_SCRIPT" 2>/dev/null; then
    SYNTAX_OK="pass"
else
    SYNTAX_OK="fail"
fi
assert_eq "test_bash_syntax_still_passes" "pass" "$SYNTAX_OK"
