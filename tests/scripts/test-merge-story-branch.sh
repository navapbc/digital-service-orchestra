#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2030,SC2031  # cd/subshell patterns in test setup
# tests/scripts/test-merge-story-branch.sh
# Behavioral tests for plugins/dso/scripts/merge-story-branch.sh
#
# TDD (RED) tests — script does not exist yet; all tests expected to FAIL.
#
# Test scenarios:
#   1. test_merge_commit_contains_dso_story_merge_trailer
#   2. test_merge_is_no_ff_creates_merge_commit
#   3. test_missing_story_branch_exits_nonzero_with_stderr
#   4. test_missing_args_exits_nonzero
#
# Usage: bash tests/scripts/test-merge-story-branch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MERGE_STORY_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-story-branch.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-merge-story-branch.sh ==="

# Verify the script under test exists before running any scenario.
# This makes ALL tests fail (RED) when the script has not been implemented yet.
if [[ ! -f "$MERGE_STORY_SCRIPT" ]]; then
    echo "FAIL: script not found: $MERGE_STORY_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# =============================================================================
# Helper: set up an isolated scratch git repo
# Creates a bare-free local repo with an initial commit on 'main' and a
# story branch with one commit. Returns to main branch.
# Sets globals: _TEST_DIR
# =============================================================================
_setup_scratch_repo() {
    _TEST_DIR=$(mktemp -d /tmp/test-merge-story-branch.XXXXXX)

    git init "$_TEST_DIR" --initial-branch=main --quiet 2>/dev/null \
        || git init "$_TEST_DIR" --quiet 2>/dev/null  # fallback for older git

    (
        cd "$_TEST_DIR"
        git config user.email "test@test.com"
        git config user.name "Test"

        # Initial commit on main
        echo "init" > README.md
        git add README.md
        git commit -m "initial commit" --quiet

        # Create story branch with one commit
        git checkout -b story/test-epic/test-story-id --quiet
        echo "story work" > story.txt
        git add story.txt
        git commit -m "story work commit" --quiet

        # Return to main (session branch)
        git checkout main --quiet
    )
}

# =============================================================================
# Test 1: test_merge_commit_contains_dso_story_merge_trailer
# Given a story branch with commits
# When merge-story-branch.sh is called with <story-branch> <story-id>
# Then the merge commit message body contains "DSO-Story-Merge: <story-id>"
# =============================================================================
echo ""
echo "--- test_merge_commit_contains_dso_story_merge_trailer ---"
_snapshot_fail

_setup_scratch_repo

_T1_RC=0
_T1_STDERR=$(mktemp /tmp/test-merge-story-t1-stderr.XXXXXX)
(
    cd "$_TEST_DIR"
    bash "$MERGE_STORY_SCRIPT" "story/test-epic/test-story-id" "test-story-id" 2>"$_T1_STDERR"
) || _T1_RC=$?

assert_eq "test_merge_commit_trailer_exits_0" "0" "$_T1_RC"

_T1_COMMIT_MSG=$(cd "$_TEST_DIR" && git log -1 --format=%B HEAD 2>/dev/null || echo "")
assert_contains \
    "test_merge_commit_contains_dso_story_merge_trailer" \
    "DSO-Story-Merge: test-story-id" \
    "$_T1_COMMIT_MSG"

rm -f "$_T1_STDERR"
assert_pass_if_clean "test_merge_commit_contains_dso_story_merge_trailer"
rm -rf "$_TEST_DIR"

# =============================================================================
# Test 2: test_merge_is_no_ff_creates_merge_commit
# Given a story branch whose tip is reachable from main (fast-forward possible)
# When merge-story-branch.sh is called
# Then a merge commit is created (not a fast-forward) — HEAD has 2 parents
# =============================================================================
echo ""
echo "--- test_merge_is_no_ff_creates_merge_commit ---"
_snapshot_fail

_setup_scratch_repo

_T2_RC=0
_T2_STDERR=$(mktemp /tmp/test-merge-story-t2-stderr.XXXXXX)
(
    cd "$_TEST_DIR"
    bash "$MERGE_STORY_SCRIPT" "story/test-epic/test-story-id" "test-story-id" 2>"$_T2_STDERR"
) || _T2_RC=$?

assert_eq "test_no_ff_exits_0" "0" "$_T2_RC"

# A --no-ff merge commit has exactly 2 parents
_T2_PARENT_COUNT=$(cd "$_TEST_DIR" && git log -1 --format=%P HEAD 2>/dev/null | wc -w | tr -d ' ' || echo "0")
assert_eq "test_merge_commit_has_two_parents" "2" "$_T2_PARENT_COUNT"

rm -f "$_T2_STDERR"
assert_pass_if_clean "test_merge_is_no_ff_creates_merge_commit"
rm -rf "$_TEST_DIR"

# =============================================================================
# Test 3: test_missing_story_branch_exits_nonzero_with_stderr
# Given a branch name that does not exist in the repo
# When merge-story-branch.sh is called with that nonexistent branch
# Then it exits non-zero and writes an error message to stderr
# =============================================================================
echo ""
echo "--- test_missing_story_branch_exits_nonzero_with_stderr ---"
_snapshot_fail

_setup_scratch_repo

_T3_RC=0
_T3_STDERR=$(mktemp /tmp/test-merge-story-t3-stderr.XXXXXX)
(
    cd "$_TEST_DIR"
    bash "$MERGE_STORY_SCRIPT" "story/does-not-exist/nonexistent-id" "nonexistent-id" 2>"$_T3_STDERR"
) || _T3_RC=$?

assert_ne "test_missing_branch_exits_nonzero" "0" "$_T3_RC"

_T3_STDERR_CONTENT=$(cat "$_T3_STDERR")
# The script must emit something to stderr — exact wording is implementation detail
assert_ne "test_missing_branch_has_stderr_output" "" "$_T3_STDERR_CONTENT"

rm -f "$_T3_STDERR"
assert_pass_if_clean "test_missing_story_branch_exits_nonzero_with_stderr"
rm -rf "$_TEST_DIR"

# =============================================================================
# Test 4: test_missing_args_exits_nonzero
# Given no positional arguments are provided
# When merge-story-branch.sh is called
# Then it exits non-zero
# =============================================================================
echo ""
echo "--- test_missing_args_exits_nonzero ---"
_snapshot_fail

_setup_scratch_repo

_T4_RC=0
_T4_STDERR=$(mktemp /tmp/test-merge-story-t4-stderr.XXXXXX)
(
    cd "$_TEST_DIR"
    bash "$MERGE_STORY_SCRIPT" 2>"$_T4_STDERR"
) || _T4_RC=$?

assert_ne "test_missing_args_exits_nonzero" "0" "$_T4_RC"

rm -f "$_T4_STDERR"
assert_pass_if_clean "test_missing_args_exits_nonzero"
rm -rf "$_TEST_DIR"

# =============================================================================
print_summary
