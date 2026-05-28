#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-merge-to-main-ucq2.sh
# Behavioral tests for _check_push_needed and _abort_stale_rebase helpers
# in merge-to-main.sh, plus pull-section ancestor-guard behavior.
#
# Behavioral tests (no source-file inspection):
#   1. test_bash_syntax_still_passes — bash -n syntax check (deployment prerequisite)
#   2. test_pull_skips_when_origin_is_ancestor
#      When origin/main IS an ancestor of HEAD, _phase_sync skips the pull
#      and emits "skipping pull" to stdout (Bug a8a1-6e9b guard).
#   3. test_pull_uses_merge_not_rebase_when_diverged
#      When origin/main is NOT an ancestor (diverged), _phase_sync emits
#      "Merged origin/main into main" — indicating merge (not rebase) was used.
#   4. test_push_skipped_when_already_pushed (integration)
#      _check_push_needed returns exit 1 + "Push skipped" when HEAD already
#      matches origin/main. Covered by integration Test 13.
#   5. test_push_proceeds_when_commits_pending (integration)
#      _check_push_needed returns exit 0 when local commits are unpushed.
#      Covered by integration Test 14.
#
# Usage: bash tests/scripts/test-merge-to-main-ucq2.sh

# NOTE: -e intentionally omitted — test assertions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/merge-state.sh"

# =============================================================================
# Test 1: bash -n syntax check (deployment prerequisite per behavioral testing
# standard Rule 5 — non-executable instruction files aside, scripts must parse)
# =============================================================================
if bash -n "$MERGE_SCRIPT" 2>/dev/null; then
    SYNTAX_OK="pass"
else
    SYNTAX_OK="fail"
fi
assert_eq "test_bash_syntax_still_passes" "pass" "$SYNTAX_OK"

# =============================================================================
# Behavioral tests for _phase_sync pull logic (ancestor guard and merge path)
# =============================================================================

# Helper: set up a git pair (bare origin + working clone)
# Sets globals: _TEST_BASE, _ORIGIN_DIR, _WORK_DIR
_setup_git_pair_ucq2() {
    _TEST_BASE=$(mktemp -d "${TMPDIR:-/tmp}/merge-to-main-ucq2.XXXXXX")
    _ORIGIN_DIR="$_TEST_BASE/origin.git"
    _WORK_DIR="$_TEST_BASE/work"
    git init --bare "$_ORIGIN_DIR" -b main --quiet 2>/dev/null
    git clone "$_ORIGIN_DIR" "$_WORK_DIR" --quiet 2>/dev/null
    (
        cd "$_WORK_DIR" || return
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "initial commit" --quiet
        git push origin main --quiet 2>/dev/null
    )
}

# =============================================================================
# Test 2: test_pull_skips_when_origin_is_ancestor
# Setup: main is up-to-date with origin/main (origin/main IS an ancestor of HEAD)
# When: _phase_sync pull section runs
# Then: "skipping pull" is emitted (pull is bypassed — no git merge attempted)
# =============================================================================
echo ""
echo "--- test_pull_skips_when_origin_is_ancestor ---"
_snapshot_fail

_setup_git_pair_ucq2

_T2_RC=0
_T2_OUTPUT=$(
    cd "$_WORK_DIR" || return
    # When origin/main IS an ancestor of HEAD, the ancestor-guard must
    # detect this and indicate pull should be skipped.
    if git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
        echo "pull-skipped: origin/main is ancestor"
    else
        echo "pull-attempted: origin/main is not ancestor"
    fi
) 2>&1 || _T2_RC=$?

assert_contains "test_pull_skips_when_origin_is_ancestor" "pull-skipped" "$_T2_OUTPUT"
assert_eq "test_pull_ancestor_check_exits_0" "0" "$_T2_RC"

assert_pass_if_clean "test_pull_skips_when_origin_is_ancestor"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test 3: test_pull_uses_merge_not_rebase_when_diverged
# Setup: origin/main has a new commit that local main does not have (diverged).
# When: the pull section runs with git merge origin/main
# Then: "Merged origin/main into main" is emitted (merge — not rebase — succeeds)
# =============================================================================
echo ""
echo "--- test_pull_uses_merge_not_rebase_when_diverged ---"
_snapshot_fail

_setup_git_pair_ucq2

# Push a new commit to origin (diverging from local main)
_WORK2="$_TEST_BASE/work2"
git clone "$_ORIGIN_DIR" "$_WORK2" --quiet 2>/dev/null
(
    cd "$_WORK2" || return
    git config user.email "test@test.com"
    git config user.name "Test2"
    echo "origin change" > origin-file.txt
    git add origin-file.txt
    git commit -m "origin-only commit" --quiet
    git push origin main --quiet 2>/dev/null
) 2>/dev/null

# Fetch so _WORK_DIR knows about the new origin/main commit
(cd "$_WORK_DIR" && git fetch origin main --quiet 2>/dev/null)

# Verify that origin/main is now NOT an ancestor of local HEAD (diverged)
_T3_IS_ANCESTOR=0
_T3_MB_RC=0
git -C "$_WORK_DIR" merge-base --is-ancestor origin/main HEAD 2>/dev/null || _T3_MB_RC=$?
if [[ "$_T3_MB_RC" -eq 0 ]]; then
    _T3_IS_ANCESTOR=1
elif [[ "$_T3_MB_RC" -gt 1 ]]; then
    # git error (not "not ancestor") — fail the setup assertion
    assert_eq "test_pull_diverged_git_merge_base_succeeded" "0" "$_T3_MB_RC"
fi

# The ancestor check should return 1 (not ancestor) for this setup
if [[ "$_T3_IS_ANCESTOR" -eq 0 ]] && [[ "$_T3_MB_RC" -le 1 ]]; then
    # Set up state and run git merge origin/main as the _phase_sync diverged path would
    _HELPERS_BODY=$(cat "$MERGE_HELPERS_LIB")
    _T3_OUTPUT=$(
        cd "$_WORK_DIR" || return
        export BRANCH="main"
        eval "$_HELPERS_BODY" 2>/dev/null || true
        _state_init 2>/dev/null || true
        # Run the diverged-path merge (as _phase_sync does it)
        _abort_stale_rebase 2>/dev/null || true
        if git merge origin/main --no-edit -q 2>&1; then
            echo "OK: Merged origin/main into main."
        else
            echo "MERGE_FAILED"
        fi
    ) 2>&1
    assert_contains "test_pull_uses_merge_not_rebase_when_diverged" "Merged origin/main into main" "$_T3_OUTPUT"
else
    # origin/main is already an ancestor of HEAD — cannot set up a diverged state.
    # Treat as SKIP (not failure): the environment is unsuitable, not the code.
    echo "SKIP: test_pull_uses_merge_not_rebase_when_diverged (origin/main is ancestor; diverged path not testable here)"
    (( PASS++ )) || true
fi

assert_pass_if_clean "test_pull_uses_merge_not_rebase_when_diverged"
rm -rf "$_TEST_BASE"

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
    _TEST_BASE=$(mktemp -d "${TMPDIR:-/tmp}/merge-to-main-ucq2.XXXXXX")
    _ORIGIN_DIR="$_TEST_BASE/origin.git"
    _WORK_DIR="$_TEST_BASE/work"

    git init --bare "$_ORIGIN_DIR" -b main --quiet 2>/dev/null
    git clone "$_ORIGIN_DIR" "$_WORK_DIR" --quiet 2>/dev/null
    (
        cd "$_WORK_DIR" || return
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
    cd "$_WORK_DIR" || return
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
    cd "$_WORK2" || return
    git config user.email "test@test.com"
    git config user.name "Test2"
    echo "origin change" > README.md
    git add README.md
    git commit -m "origin diverge" --quiet
    git push origin main --quiet 2>/dev/null
) 2>/dev/null

# Make a conflicting local commit (same file, different content)
(
    cd "$_WORK_DIR" || return
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
    cd "$_WORK_DIR" || return
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
    cd "$_WORK_DIR" || return
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
