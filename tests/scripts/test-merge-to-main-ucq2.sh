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
