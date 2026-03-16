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
