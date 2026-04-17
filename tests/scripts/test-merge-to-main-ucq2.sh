#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-merge-to-main-ucq2.sh
# Tests for _check_push_needed helper in merge-to-main.sh
#
# TDD tests:
#   1. test_check_push_needed_exists_as_function — _check_push_needed() defined in script
#   2. test_check_push_needed_git_fetch_called — function body contains 'git fetch origin'
#   3. test_check_push_needed_git_log_check — function body contains 'git log origin/main..HEAD'
#   4. test_check_push_needed_skip_message — function body contains 'Push skipped' message
#   5. test_check_push_needed_fetch_failure_returns_push_needed — fetch failure returns 0 (push needed)
#
# Usage: bash tests/scripts/test-merge-to-main-ucq2.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/merge-state.sh"

# =============================================================================
# Test 1: _check_push_needed function exists in merge-to-main.sh
# =============================================================================
HAS_FUNCTION=$(grep -c '_check_push_needed()' "$MERGE_SCRIPT" "$MERGE_HELPERS_LIB" 2>/dev/null || true)
assert_ne "test_check_push_needed_exists_as_function" "0" "$HAS_FUNCTION"

# =============================================================================
# Test 2: Function body includes git fetch origin
# The function should fetch the latest remote state before checking.
# =============================================================================
FUNC_BODY=$(sed -n '/_check_push_needed()/,/^}/p' "$MERGE_SCRIPT")
[[ -z "$FUNC_BODY" ]] && FUNC_BODY=$(sed -n '/_check_push_needed()/,/^}/p' "$MERGE_HELPERS_LIB" 2>/dev/null || true)
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
HAS_ABORT_FUNC=$(grep -c '_abort_stale_rebase()' "$MERGE_SCRIPT" "$MERGE_HELPERS_LIB" 2>/dev/null || true)
assert_ne "test_abort_stale_rebase_exists_as_function" "0" "$HAS_ABORT_FUNC"

# =============================================================================
# Test 7: _abort_stale_rebase checks for REBASE_HEAD
# The function should check for a stale rebase state file.
# =============================================================================
ABORT_FUNC_BODY=$(sed -n '/_abort_stale_rebase()/,/^}/p' "$MERGE_SCRIPT")
[[ -z "$ABORT_FUNC_BODY" ]] && ABORT_FUNC_BODY=$(sed -n '/_abort_stale_rebase()/,/^}/p' "$MERGE_HELPERS_LIB" 2>/dev/null || true)
HAS_REBASE_CHECK=$(echo "$ABORT_FUNC_BODY" | grep -cE 'REBASE_HEAD|ms_is_rebase_in_progress' || true)
assert_ne "test_abort_stale_rebase_checks_rebase_head" "0" "$HAS_REBASE_CHECK"

# =============================================================================
# Test 8: Pull section uses ancestor check before attempting merge
# Bug a8a1-6e9b: replaced unconditional git pull --rebase with ancestor guard.
# When origin/main is ancestor of HEAD, pull is skipped entirely.
# =============================================================================
HAS_ANCESTOR_CHECK=$(grep -c 'merge-base --is-ancestor origin/main HEAD' "$MERGE_SCRIPT" || true)
assert_ne "test_pull_section_has_ancestor_guard" "0" "$HAS_ANCESTOR_CHECK"

# =============================================================================
# Test 9: Pull section uses git merge (not rebase) for diverged case
# Bug a8a1-6e9b: when origin/main is NOT an ancestor, merge is more tolerant
# than rebase for bringing origin/main into main.
# =============================================================================
PHASE_SYNC_BODY_PULL=$(sed -n '/_phase_sync()/,/^}/p' "$MERGE_SCRIPT")
HAS_MERGE_ORIGIN=$(echo "$PHASE_SYNC_BODY_PULL" | grep -c 'git merge origin/main' || true)
assert_ne "test_pull_section_uses_merge_not_rebase" "0" "$HAS_MERGE_ORIGIN"

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
# Test 11: Pull section calls _abort_stale_rebase before merge in diverged path
# The sync phase should clean up stale rebase state BEFORE attempting merge
# with origin/main in the diverged (non-ancestor) code path.
# =============================================================================
# Extract the pull section specifically (after "Pulling remote changes")
PULL_SECTION_BODY=$(sed -n '/Pulling remote changes/,/OK: Pulled remote/p' "$MERGE_SCRIPT")
ABORT_LINE=$(echo "$PULL_SECTION_BODY" | grep -n '_abort_stale_rebase' | head -1 | cut -d: -f1)
MERGE_LINE=$(echo "$PULL_SECTION_BODY" | grep -n 'git merge origin/main' | head -1 | cut -d: -f1)
if [[ -n "$ABORT_LINE" && -n "$MERGE_LINE" && "$ABORT_LINE" -lt "$MERGE_LINE" ]]; then
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

# =============================================================================
# INTEGRATION TESTS — real temp git repos
# =============================================================================

echo ""
echo "=== Integration tests (temp git repos) ==="

# --- Helper: extract a function from merge-to-main.sh (or merge-helpers.sh) by name ---
_extract_fn() {
    local fn_name="$1"
    local _body
    _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT")
    if [[ -z "$_body" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_HELPERS_LIB")
    fi
    echo "$_body"
}

# --- Helper: create a bare "origin" repo and a cloned working repo ---
# Sets globals: _TEST_BASE, _ORIGIN_DIR, _WORK_DIR
_setup_git_pair() {
    _TEST_BASE=$(mktemp -d)
    _ORIGIN_DIR="$_TEST_BASE/origin.git"
    _WORK_DIR="$_TEST_BASE/work"

    git init --bare "$_ORIGIN_DIR" -b main --quiet 2>/dev/null
    git clone "$_ORIGIN_DIR" "$_WORK_DIR" --quiet 2>/dev/null
    (
        cd "$_WORK_DIR"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "initial commit" --quiet
        git push origin main --quiet 2>/dev/null
    )
}

# Source the functions under test
eval "$(_extract_fn "_check_push_needed")"
eval "$(_extract_fn "_abort_stale_rebase")"
eval "$(_extract_fn "_set_phase_status")"
eval "$(_extract_fn "_state_file_path")"
eval "$(_extract_fn "_state_is_fresh")"
eval "$(_extract_fn "_state_init")"
eval "$(_extract_fn "_state_write_phase")"
eval "$(_extract_fn "_state_mark_complete")"

# =============================================================================
# Test 13: test_push_skipped_when_origin_already_contains_head
# Setup: push a commit so origin already contains HEAD. _check_push_needed
# should return 1 (push not needed) and emit "Push skipped".
# =============================================================================
echo ""
echo "--- test_push_skipped_when_origin_already_contains_head ---"
_snapshot_fail

_setup_git_pair

# Run _check_push_needed in the work dir where HEAD matches origin/main
_T13_RC=0
_T13_OUTPUT=$(cd "$_WORK_DIR" && _check_push_needed 2>&1) || _T13_RC=$?

# _check_push_needed returns 1 when push is NOT needed
assert_eq "test_push_skipped_returns_exit_1" "1" "$_T13_RC"
assert_contains "test_push_skipped_message" "Push skipped" "$_T13_OUTPUT"

assert_pass_if_clean "test_push_skipped_when_origin_already_contains_head"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 14: test_push_proceeds_when_commits_pending
# Setup: make a local commit that is NOT pushed. _check_push_needed should
# return 0 (push needed).
# =============================================================================
echo ""
echo "--- test_push_proceeds_when_commits_pending ---"
_snapshot_fail

_setup_git_pair
(
    cd "$_WORK_DIR"
    echo "new content" > newfile.txt
    git add newfile.txt
    git commit -m "local-only commit" --quiet
) 2>/dev/null

_T14_RC=0
_T14_OUTPUT=$(cd "$_WORK_DIR" && _check_push_needed 2>&1) || _T14_RC=$?

# _check_push_needed returns 0 when push IS needed
assert_eq "test_push_proceeds_returns_exit_0" "0" "$_T14_RC"

assert_pass_if_clean "test_push_proceeds_when_commits_pending"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 15: test_pull_conflict_records_conflict_state
# Verify that when git pull --rebase fails, the conflict path records
# conflict status via _set_phase_status and emits CONFLICT_DATA.
# =============================================================================
echo ""
echo "--- test_pull_conflict_records_conflict_state ---"
_snapshot_fail

_setup_git_pair

# Create divergent history: push a conflicting commit to origin from a second clone
_WORK2="$_TEST_BASE/work2"
git clone "$_ORIGIN_DIR" "$_WORK2" --quiet 2>/dev/null
(
    cd "$_WORK2"
    git config user.email "test@test.com"
    git config user.name "Test2"
    echo "origin change" > README.md
    git add README.md
    git commit -m "origin diverge" --quiet
    git push origin main --quiet 2>/dev/null
) 2>/dev/null

# Make a conflicting local commit (same file, different content)
(
    cd "$_WORK_DIR"
    echo "local change" > README.md
    git add README.md
    git commit -m "local diverge" --quiet
) 2>/dev/null

# Set up state file so _set_phase_status has something to write to.
# Use a PID-suffixed branch name so concurrent test instances don't race on
# the same /tmp/merge-to-main-state-test-conflict-integ.json file.
BRANCH="test-conflict-integ-$$"
_state_init
_STATE_FILE=$(_state_file_path)

# Simulate the conflict path from merge-to-main.sh _phase_sync
_T15_OUTPUT=$(
    cd "$_WORK_DIR"
    _abort_stale_rebase
    if ! git pull --rebase 2>&1; then
        _abort_stale_rebase
        _set_phase_status "pull_rebase" "conflict"
        echo "CONFLICT_DATA: phase=pull_rebase branch=$BRANCH"
        git rebase --abort 2>/dev/null || true
    fi
) 2>&1

# Verify CONFLICT_DATA was emitted
assert_contains "test_pull_conflict_emits_conflict_data_integration" "CONFLICT_DATA" "$_T15_OUTPUT"
assert_contains "test_pull_conflict_emits_phase_pull_rebase" "phase=pull_rebase" "$_T15_OUTPUT"

# Verify state file recorded conflict status
_T15_STATUS=$(python3 -c "
import json
try:
    with open('$_STATE_FILE') as f:
        d = json.load(f)
    print(d.get('phases', {}).get('pull_rebase', {}).get('status', ''))
except Exception as e:
    print('error: ' + str(e))
" 2>/dev/null || echo "error")
assert_eq "test_pull_conflict_state_file_has_conflict_status" "conflict" "$_T15_STATUS"

assert_pass_if_clean "test_pull_conflict_records_conflict_state"
rm -f "$_STATE_FILE"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 16: test_abort_stale_rebase_aborts_when_rebase_head_present
# Setup: create a fake REBASE_HEAD file in .git/. _abort_stale_rebase should
# remove it and emit "Aborted stale rebase".
# =============================================================================
echo ""
echo "--- test_abort_stale_rebase_aborts_when_rebase_head_present ---"
_snapshot_fail

_setup_git_pair
(
    cd "$_WORK_DIR"
    _GIT_DIR=$(git rev-parse --git-dir)
    # Create minimal rebase state so git rebase --abort can proceed
    mkdir -p "$_GIT_DIR/rebase-merge"
    echo "refs/heads/main" > "$_GIT_DIR/rebase-merge/head-name"
    echo "$(git rev-parse HEAD)" > "$_GIT_DIR/rebase-merge/orig-head"
    echo "$(git rev-parse HEAD)" > "$_GIT_DIR/rebase-merge/onto"
    echo "0" > "$_GIT_DIR/rebase-merge/msgnum"
    echo "0" > "$_GIT_DIR/rebase-merge/end"
    touch "$_GIT_DIR/REBASE_HEAD"
) 2>/dev/null

_T16_OUTPUT=$(cd "$_WORK_DIR" && _abort_stale_rebase 2>&1)

# Verify REBASE_HEAD is gone
_T16_GIT_DIR=$(cd "$_WORK_DIR" && git rev-parse --git-dir)
if [[ ! -f "$_T16_GIT_DIR/REBASE_HEAD" ]]; then
    _REBASE_HEAD_GONE="true"
else
    _REBASE_HEAD_GONE="false"
fi
assert_eq "test_abort_stale_rebase_removes_rebase_head" "true" "$_REBASE_HEAD_GONE"
assert_contains "test_abort_stale_rebase_emits_message" "Aborted stale rebase" "$_T16_OUTPUT"

assert_pass_if_clean "test_abort_stale_rebase_aborts_when_rebase_head_present"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 17: test_abort_stale_rebase_noop_when_no_rebase_head
# Setup: no REBASE_HEAD file. _abort_stale_rebase should exit 0 silently.
# =============================================================================
echo ""
echo "--- test_abort_stale_rebase_noop_when_no_rebase_head ---"
_snapshot_fail

_setup_git_pair

# Ensure no REBASE_HEAD exists
_T17_GIT_DIR=$(cd "$_WORK_DIR" && git rev-parse --git-dir)
rm -f "$_T17_GIT_DIR/REBASE_HEAD" 2>/dev/null

_T17_RC=0
_T17_OUTPUT=$(cd "$_WORK_DIR" && _abort_stale_rebase 2>&1) || _T17_RC=$?

assert_eq "test_abort_stale_rebase_noop_exits_0" "0" "$_T17_RC"
# Should NOT contain the abort message (no-op case)
if [[ "$_T17_OUTPUT" == *"Aborted stale rebase"* ]]; then
    _T17_NO_MSG="false"
else
    _T17_NO_MSG="true"
fi
assert_eq "test_abort_stale_rebase_noop_no_abort_message" "true" "$_T17_NO_MSG"

assert_pass_if_clean "test_abort_stale_rebase_noop_when_no_rebase_head"
rm -rf "$_TEST_BASE"

# =============================================================================
print_summary
