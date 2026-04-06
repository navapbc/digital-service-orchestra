#!/usr/bin/env bash
# tests/hooks/test-merge-state-worktree.sh
# RED tests for merge-state.sh worktree-to-session merge semantics.
#
# Scenario: A Claude Code worktree (created with `git worktree add`) has
# implementation changes committed on its branch. After review and commit in the
# worktree, those changes are merged back into the session (main) branch.
#
# Semantic inversion problem (the gap this tests for):
#   ms_get_worktree_only_files was designed for merge-to-main flow:
#     - HEAD = worktree/feature branch (your work)
#     - MERGE_HEAD = main/session branch (incoming, already-reviewed)
#     - Returns: diff(merge_base..HEAD) = your files (correct: keep yours, skip incoming)
#
#   During worktree-to-session merge, the topology is INVERTED:
#     - HEAD = session branch (orchestrator work)
#     - MERGE_HEAD = worktree branch (implementation work, already reviewed in worktree)
#     - Current behavior: diff(merge_base..HEAD) = session-side files ONLY
#     - DESIRED behavior: must NOT exclude the worktree's implementation files,
#       because they are the reviewed, committed work we want to merge in
#
#   New required function: ms_get_incoming_only_files (or equivalent) that
#   returns files on MERGE_HEAD branch (diff merge_base..MERGE_HEAD) — the
#   semantic inverse of ms_get_worktree_only_files. The review gate uses this
#   to identify worktree branch files during worktree-to-session merges.
#
# These tests are RED against current merge-state.sh because:
#   1. ms_get_incoming_only_files does not exist yet
#   2. ms_get_worktree_only_files does not accept a --incoming flag
#   3. No worktree-aware merge direction detection exists
#
# Tests:
#  1. test_worktree_to_session_merge_detected
#     - Verifies ms_is_merge_in_progress works correctly in git-worktree topology
#     - RED: checks for a worktree-specific detection signal (ms_is_worktree_merge)
#       that does not yet exist
#  2. test_worktree_only_files_includes_implementation
#     - Verifies that the worktree's implementation files are returned (not excluded)
#       via a new ms_get_incoming_only_files function that does not yet exist
#  3. test_review_gate_skips_merge_commit
#     - Verifies that a new ms_is_worktree_to_session_merge function exists and
#       returns true for the worktree-to-session merge topology
#
# Usage: bash tests/hooks/test-merge-state-worktree.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_STATE_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-state.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-state-worktree.sh ==="

# ── Cleanup on exit ───────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        # Prune any linked worktrees before removing tmpdir
        git -C "$d/session" worktree prune 2>/dev/null || true
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite check ────────────────────────────────────────────────────────
if [[ ! -f "$MERGE_STATE_LIB" ]]; then
    echo "SKIP: merge-state.sh not found at $MERGE_STATE_LIB" >&2
    for _test_name in \
        test_worktree_to_session_merge_detected \
        test_worktree_only_files_includes_implementation \
        test_review_gate_skips_merge_commit; do
        echo "FAIL: $_test_name"
        (( ++FAIL ))
    done
    print_summary
fi

# Source the library under test
# shellcheck source=/dev/null
source "$MERGE_STATE_LIB"

# ── Helper: make a worktree-to-session merge repo ────────────────────────────
# Creates a repo that simulates a Claude Code worktree session being merged
# back into the main session branch, using a real git worktree.
#
# Structure:
#   $tmpdir/origin.git      — bare remote
#   $tmpdir/session         — main checkout (session branch), mid-merge
#   $tmpdir/wt              — linked git worktree (worktree branch)
#
# Files:
#   base.txt                — initial commit (shared base)
#   session-file.txt        — added on session branch (HEAD-side change)
#   worktree-impl.txt       — added on worktree branch (MERGE_HEAD-side: implementation)
#   worktree-impl2.txt      — second file added on worktree branch
#
# State: session repo is mid-merge (MERGE_HEAD = worktree branch tip)
# Returns: $tmpdir on stdout (so caller can derive $tmpdir/session, etc.)
_make_worktree_to_session_merge_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    # Create bare remote
    git init --bare -b main "$tmpdir/origin.git" --quiet 2>/dev/null || \
        git init --bare "$tmpdir/origin.git" --quiet

    # Clone into session directory
    git clone "$tmpdir/origin.git" "$tmpdir/session" --quiet 2>/dev/null
    git -C "$tmpdir/session" config user.email "test@test.com"
    git -C "$tmpdir/session" config user.name "Test"

    # Initial commit on main
    echo "base content" > "$tmpdir/session/base.txt"
    git -C "$tmpdir/session" add base.txt
    git -C "$tmpdir/session" commit -m "initial: add base.txt" --quiet
    git -C "$tmpdir/session" push origin main --quiet 2>/dev/null

    # Create worktree branch from current HEAD (the shared base)
    git -C "$tmpdir/session" branch worktree-20260405-210543 --quiet

    # Add a linked git worktree for the worktree branch
    git -C "$tmpdir/session" worktree add "$tmpdir/wt" worktree-20260405-210543 --quiet 2>/dev/null
    git -C "$tmpdir/wt" config user.email "test@test.com"
    git -C "$tmpdir/wt" config user.name "Test"

    # Make implementation changes in the worktree (the sub-agent's work)
    echo "worktree implementation" > "$tmpdir/wt/worktree-impl.txt"
    git -C "$tmpdir/wt" add worktree-impl.txt
    git -C "$tmpdir/wt" commit -m "feat: add worktree-impl.txt" --quiet

    echo "more worktree work" > "$tmpdir/wt/worktree-impl2.txt"
    git -C "$tmpdir/wt" add worktree-impl2.txt
    git -C "$tmpdir/wt" commit -m "feat: add worktree-impl2.txt" --quiet

    # Add a session-side change so the two branches diverge
    echo "session side work" > "$tmpdir/session/session-file.txt"
    git -C "$tmpdir/session" add session-file.txt
    git -C "$tmpdir/session" commit -m "session: add session-file.txt" --quiet

    # Merge the worktree branch into session (no-commit so MERGE_HEAD persists)
    local worktree_branch_sha
    worktree_branch_sha=$(git -C "$tmpdir/wt" rev-parse HEAD)
    git -C "$tmpdir/session" merge "$worktree_branch_sha" --no-commit --no-edit 2>/dev/null || true

    echo "$tmpdir"
}

# =============================================================================
# Test 1: test_worktree_to_session_merge_detected
# =============================================================================
# Asserts that merge-state.sh exposes a function ms_is_worktree_to_session_merge
# that detects when the MERGE_HEAD branch was a git-worktree-linked branch
# (i.e., the current merge is bringing in changes from a `git worktree add`
# branch, not from a remote or a manually-created branch).
#
# RED because: ms_is_worktree_to_session_merge does NOT exist in merge-state.sh.
# The current code only has ms_is_merge_in_progress (generic MERGE_HEAD detection).
# Worktree-to-session detection requires checking whether MERGE_HEAD's branch
# was associated with a linked worktree — a topology-specific detection that
# needs to be added.
test_worktree_to_session_merge_detected() {
    _snapshot_fail

    local tmpdir session_repo session_git_dir result
    tmpdir=$(cd /tmp && _make_worktree_to_session_merge_repo)
    session_repo="$tmpdir/session"
    session_git_dir=$(git -C "$session_repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Verify precondition: MERGE_HEAD exists (generic merge in progress)
    assert_eq "setup: MERGE_HEAD present in session git dir" \
        "1" "$(test -f "$session_git_dir/MERGE_HEAD" && echo 1 || echo 0)"

    # Verify generic merge detection works (should pass — this is baseline)
    result=1
    (cd "$session_repo" && _MERGE_STATE_GIT_DIR="$session_git_dir" ms_is_merge_in_progress) && result=0 || true
    assert_eq "test_worktree_to_session_merge_detected: ms_is_merge_in_progress baseline works" \
        "0" "$result"

    # Assert the NEW function ms_is_worktree_to_session_merge exists and returns true.
    # This function does NOT exist yet — test will FAIL here.
    result=1
    if declare -f ms_is_worktree_to_session_merge > /dev/null 2>&1; then
        (cd "$session_repo" && _MERGE_STATE_GIT_DIR="$session_git_dir" ms_is_worktree_to_session_merge) && result=0 || true
    fi

    assert_eq "test_worktree_to_session_merge_detected: ms_is_worktree_to_session_merge exists and returns true for git-worktree merge" \
        "0" "$result"

    assert_pass_if_clean "test_worktree_to_session_merge_detected"
}

# =============================================================================
# Test 2: test_worktree_only_files_includes_implementation
# =============================================================================
# During a worktree-to-session merge:
#   - HEAD = session branch (orchestrator)
#   - MERGE_HEAD = worktree branch (implementation, already reviewed)
#
# The worktree's implementation files (worktree-impl.txt, worktree-impl2.txt)
# are on the MERGE_HEAD side. A new function ms_get_incoming_only_files must
# return these files so the orchestrator can verify the merge contains the
# expected implementation work.
#
# Currently ms_get_worktree_only_files returns diff(merge_base..HEAD) =
# session-side files only (session-file.txt). The implementation files on
# the MERGE_HEAD side are NOT returned by any existing function.
#
# RED because: ms_get_incoming_only_files does not exist yet. This test calls
# it and expects worktree-impl.txt and worktree-impl2.txt to be returned.
test_worktree_only_files_includes_implementation() {
    _snapshot_fail

    local tmpdir session_repo session_git_dir incoming_files has_impl has_impl2 has_session
    tmpdir=$(cd /tmp && _make_worktree_to_session_merge_repo)
    session_repo="$tmpdir/session"
    session_git_dir=$(git -C "$session_repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Verify precondition: merge is in progress
    assert_eq "setup: MERGE_HEAD present for incoming files test" \
        "1" "$(test -f "$session_git_dir/MERGE_HEAD" && echo 1 || echo 0)"

    # Call ms_get_incoming_only_files — returns files on MERGE_HEAD branch
    # (i.e., the worktree's implementation changes). Does NOT exist yet.
    incoming_files=""
    if declare -f ms_get_incoming_only_files > /dev/null 2>&1; then
        incoming_files=$(cd "$session_repo" && \
            _MERGE_STATE_GIT_DIR="$session_git_dir" ms_get_incoming_only_files 2>/dev/null || echo "FAILED")
    else
        incoming_files="FUNCTION_MISSING"
    fi

    assert_ne "test_worktree_only_files_includes_implementation: ms_get_incoming_only_files exists (not FUNCTION_MISSING)" \
        "FUNCTION_MISSING" "$incoming_files"

    assert_ne "test_worktree_only_files_includes_implementation: ms_get_incoming_only_files did not fail" \
        "FAILED" "$incoming_files"

    # worktree-impl.txt is on the MERGE_HEAD (worktree) branch — must be INCLUDED
    has_impl=0
    [[ "$incoming_files" =~ worktree-impl.txt ]] && has_impl=1
    assert_eq "test_worktree_only_files_includes_implementation: worktree-impl.txt included (incoming worktree implementation file)" \
        "1" "$has_impl"

    # worktree-impl2.txt is also on the MERGE_HEAD (worktree) branch — must be INCLUDED
    has_impl2=0
    [[ "$incoming_files" =~ worktree-impl2.txt ]] && has_impl2=1
    assert_eq "test_worktree_only_files_includes_implementation: worktree-impl2.txt included (incoming worktree implementation file)" \
        "1" "$has_impl2"

    # session-file.txt is on HEAD branch (session-side) — must be EXCLUDED from incoming
    has_session=0
    [[ "$incoming_files" =~ session-file.txt ]] && has_session=1
    assert_eq "test_worktree_only_files_includes_implementation: session-file.txt excluded (not on incoming worktree branch)" \
        "0" "$has_session"

    assert_pass_if_clean "test_worktree_only_files_includes_implementation"
}

# =============================================================================
# Test 3: test_review_gate_skips_merge_commit
# =============================================================================
# During a worktree-to-session merge, the review gate should allow the merge
# commit to proceed without requiring a new review (the worktree branch was
# already reviewed before being committed there).
#
# The current ms_is_merge_in_progress + ms_get_merge_base chain works for
# the generic case. But for the worktree-to-session topology specifically,
# the review gate needs to:
#   1. Detect the merge is in progress (ms_is_merge_in_progress — already works)
#   2. Identify that the incoming files are the worktree's implementation work
#      (ms_get_incoming_only_files — does NOT exist yet)
#   3. Verify that those files were already reviewed in the worktree context
#      (new logic that reads worktree ARTIFACTS_DIR review-status — does NOT exist)
#
# This test asserts that ms_get_incoming_only_files exists and that it returns
# the correct files for the review gate to inspect. Since it does not exist,
# the test is RED.
#
# Additionally tests that ms_is_merge_in_progress correctly returns true
# when called from within a real linked git worktree (not the session repo),
# since hooks may run from either directory context.
test_review_gate_skips_merge_commit() {
    _snapshot_fail

    local tmpdir session_repo wt_repo session_git_dir wt_git_dir merge_detected
    tmpdir=$(cd /tmp && _make_worktree_to_session_merge_repo)
    session_repo="$tmpdir/session"
    wt_repo="$tmpdir/wt"
    session_git_dir=$(git -C "$session_repo" rev-parse --absolute-git-dir 2>/dev/null)
    wt_git_dir=$(git -C "$wt_repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Verify precondition: MERGE_HEAD is in session git dir (not worktree git dir)
    assert_eq "setup: MERGE_HEAD present in session (not worktree) git dir" \
        "1" "$(test -f "$session_git_dir/MERGE_HEAD" && echo 1 || echo 0)"

    assert_eq "setup: MERGE_HEAD absent in worktree git dir (worktree has no pending merge)" \
        "0" "$(test -f "$wt_git_dir/MERGE_HEAD" && echo 1 || echo 0)"

    # Review gate detects MERGE_HEAD when called from session repo context
    merge_detected=1
    (cd "$session_repo" && _MERGE_STATE_GIT_DIR="$session_git_dir" ms_is_merge_in_progress) && merge_detected=0 || true
    assert_eq "test_review_gate_skips_merge_commit: review gate detects MERGE_HEAD in session repo" \
        "0" "$merge_detected"

    # Assert ms_get_incoming_only_files exists — this is what the review gate would
    # call to identify the worktree's implementation files and verify they were reviewed.
    # Does NOT exist yet — RED.
    local fn_exists=0
    declare -f ms_get_incoming_only_files > /dev/null 2>&1 && fn_exists=1 || true

    assert_eq "test_review_gate_skips_merge_commit: ms_get_incoming_only_files function exists in merge-state.sh" \
        "1" "$fn_exists"

    # When ms_get_incoming_only_files exists, it must return worktree impl files
    # so the review gate can verify them against the worktree's review-status.
    if [[ "$fn_exists" -eq 1 ]]; then
        local incoming_files
        incoming_files=$(cd "$session_repo" && \
            _MERGE_STATE_GIT_DIR="$session_git_dir" ms_get_incoming_only_files 2>/dev/null || echo "")

        local has_impl=0
        [[ "$incoming_files" =~ worktree-impl.txt ]] && has_impl=1
        assert_eq "test_review_gate_skips_merge_commit: ms_get_incoming_only_files returns worktree impl files" \
            "1" "$has_impl"
    fi

    assert_pass_if_clean "test_review_gate_skips_merge_commit"
}

# =============================================================================
# Run all tests
# =============================================================================
echo ""
test_worktree_to_session_merge_detected
echo ""
test_worktree_only_files_includes_implementation
echo ""
test_review_gate_skips_merge_commit

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
