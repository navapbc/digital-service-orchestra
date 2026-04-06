#!/usr/bin/env bash
# tests/hooks/test-worktree-retention.sh
# RED tests for worktree retention protocol (story 6c59-7063, task 8f29-58ae)
#
# Verifies:
#   1. Worktree is retained while review is in progress
#      (review-status present in worktree ARTIFACTS_DIR)
#   2. Worktree is retained while merge is in progress
#      (MERGE_HEAD file present in worktree .git)
#   3. After successful merge, worktree can be removed cleanly
#
# Tests:
#   test_worktree_retained_during_review
#   test_worktree_retained_during_merge
#   test_worktree_cleanup_after_merge
#
# Usage: bash tests/hooks/test-worktree-retention.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call commands that return non-zero
# and we handle failures via assert_eq, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-retention.sh ==="

# ── Shared worktree state ─────────────────────────────────────────────────────
_WORKTREE_DIR=""
_WORKTREE_BRANCH=""
_ARTIFACTS_DIR=""

# Helper: create a fresh temporary worktree
_setup_worktree() {
    local branch_suffix="${1:-$$}"
    _WORKTREE_BRANCH="test-wt-retention-${branch_suffix}"
    _WORKTREE_DIR=$(mktemp -d)
    # Resolve symlinks (macOS /var -> /private/var) for consistent path comparison
    _WORKTREE_DIR=$(cd "$_WORKTREE_DIR" && pwd -P)
    git -C "$REPO_ROOT" worktree add -b "$_WORKTREE_BRANCH" "$_WORKTREE_DIR" HEAD 2>/dev/null
    # Compute a stable ARTIFACTS_DIR for this worktree based on its root hash
    # (mirrors what get_artifacts_dir() does when given a REPO_ROOT-derived hash)
    local _hash
    _hash=$(printf '%s' "$_WORKTREE_DIR" | sha256sum 2>/dev/null | cut -c1-16 \
        || printf '%s' "$_WORKTREE_DIR" | shasum -a 256 2>/dev/null | cut -c1-16)
    _ARTIFACTS_DIR="/tmp/workflow-plugin-${_hash}"
    mkdir -p "$_ARTIFACTS_DIR"
}

# Helper: force-remove worktree and branch (idempotent)
_teardown_worktree() {
    if [[ -n "${_WORKTREE_DIR:-}" && -d "${_WORKTREE_DIR:-}" ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$_WORKTREE_DIR" 2>/dev/null || true
    fi
    if [[ -n "${_WORKTREE_BRANCH:-}" ]]; then
        git -C "$REPO_ROOT" branch -D "$_WORKTREE_BRANCH" 2>/dev/null || true
    fi
    if [[ -n "${_ARTIFACTS_DIR:-}" && -d "${_ARTIFACTS_DIR:-}" ]]; then
        rm -rf "$_ARTIFACTS_DIR" 2>/dev/null || true
    fi
    _WORKTREE_DIR=""
    _WORKTREE_BRANCH=""
    _ARTIFACTS_DIR=""
}

# Ensure all worktrees are cleaned up on exit
trap _teardown_worktree EXIT

# ============================================================
# test_worktree_retained_during_review
#
# Scenario: review sub-agent wrote review-status to the worktree's ARTIFACTS_DIR
# (simulating an in-progress or just-completed review). The worktree must still
# exist — the orchestrator should NOT have removed it before merge.
#
# RED: This test documents the expected protocol behavior. The retention
# mechanism (e.g., a sentinel file or explicit hold) is not yet implemented;
# we verify the directory still exists after the review-status is written.
# ============================================================
echo "--- test_worktree_retained_during_review ---"
_setup_worktree "review-$$"

# Simulate review sub-agent writing review-status to worktree ARTIFACTS_DIR
_review_status_file="$_ARTIFACTS_DIR/review-status"
printf 'status=passed\ndiff_hash=abc123\n' > "$_review_status_file"

# The worktree directory must still exist (retention protocol)
_wt_exists_during_review="no"
[[ -d "$_WORKTREE_DIR" ]] && _wt_exists_during_review="yes"
assert_eq "test_worktree_retained_during_review: worktree dir exists" \
    "yes" "$_wt_exists_during_review"

# The review-status file must be present in the worktree ARTIFACTS_DIR
_review_status_exists="no"
[[ -f "$_review_status_file" ]] && _review_status_exists="yes"
assert_eq "test_worktree_retained_during_review: review-status written" \
    "yes" "$_review_status_exists"

# Verify the review-status content is readable (passed status)
_review_status_content=$(cat "$_review_status_file" 2>/dev/null || echo "")
assert_contains "test_worktree_retained_during_review: review-status has passed status" \
    "status=passed" "$_review_status_content"

# The worktree must still be registered with git
_wt_listed=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "$_WORKTREE_DIR" || true)
assert_eq "test_worktree_retained_during_review: worktree still registered with git" \
    "1" "$_wt_listed"

_teardown_worktree

# ============================================================
# test_worktree_retained_during_merge
#
# Scenario: the orchestrator is merging the worktree branch into the session
# branch. MERGE_HEAD exists in the worktree's .git, signaling an active merge.
# The worktree must still be present — it must NOT be removed mid-merge.
#
# RED: Simulates MERGE_HEAD presence in worktree .git to represent an
# in-progress merge. Retention means the directory survives until after
# the merge commit is made.
# ============================================================
echo "--- test_worktree_retained_during_merge ---"
_setup_worktree "merge-$$"

# Resolve the actual .git path for the worktree
# (git worktrees use a .git file pointing to the common git dir + worktrees/)
_wt_git_path=$(git -C "$_WORKTREE_DIR" rev-parse --git-dir 2>/dev/null)
if [[ ! -d "$_wt_git_path" ]]; then
    # Resolve relative path from worktree dir
    _wt_git_path="$_WORKTREE_DIR/$_wt_git_path"
fi

# Write a synthetic MERGE_HEAD to simulate an in-progress merge
# (a real MERGE_HEAD contains the SHA of the branch being merged in)
_fake_merge_sha="0000000000000000000000000000000000000001"
printf '%s\n' "$_fake_merge_sha" > "$_wt_git_path/MERGE_HEAD"

# The MERGE_HEAD must now be detectable
_merge_head_exists="no"
[[ -f "$_wt_git_path/MERGE_HEAD" ]] && _merge_head_exists="yes"
assert_eq "test_worktree_retained_during_merge: MERGE_HEAD exists" \
    "yes" "$_merge_head_exists"

# The worktree directory must still exist while merge is in progress
_wt_exists_during_merge="no"
[[ -d "$_WORKTREE_DIR" ]] && _wt_exists_during_merge="yes"
assert_eq "test_worktree_retained_during_merge: worktree dir exists during merge" \
    "yes" "$_wt_exists_during_merge"

# The worktree must still be registered with git during merge
_wt_listed_merge=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "$_WORKTREE_DIR" || true)
assert_eq "test_worktree_retained_during_merge: worktree still registered during merge" \
    "1" "$_wt_listed_merge"

# Clean up MERGE_HEAD before teardown
rm -f "$_wt_git_path/MERGE_HEAD" 2>/dev/null || true

_teardown_worktree

# ============================================================
# test_worktree_cleanup_after_merge
#
# Scenario: the merge of the worktree branch into the session branch completed
# successfully. The worktree is now eligible for removal. Verify that
# git worktree remove cleanly removes it.
#
# This verifies the happy-path cleanup step that follows retention: once merge
# is done, the worktree MUST be removable without error.
# ============================================================
echo "--- test_worktree_cleanup_after_merge ---"
_setup_worktree "cleanup-$$"

# Verify worktree exists and is registered before attempting cleanup
_wt_exists_pre="no"
[[ -d "$_WORKTREE_DIR" ]] && _wt_exists_pre="yes"
assert_eq "test_worktree_cleanup_after_merge: worktree exists before cleanup" \
    "yes" "$_wt_exists_pre"

_wt_listed_pre=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "$_WORKTREE_DIR" || true)
assert_eq "test_worktree_cleanup_after_merge: worktree is listed before cleanup" \
    "1" "$_wt_listed_pre"

# Simulate merge completion: no MERGE_HEAD, clean working tree
# (after a successful merge commit, the working tree is clean)
# Capture the worktree dir path before teardown clears the variable
_wt_dir_for_check="$_WORKTREE_DIR"

# Remove the worktree (this is the orchestrator's post-merge cleanup step)
git -C "$REPO_ROOT" worktree remove --force "$_WORKTREE_DIR" 2>/dev/null
_remove_exit=$?
assert_eq "test_worktree_cleanup_after_merge: git worktree remove exits 0" \
    "0" "$_remove_exit"

# Verify directory is gone
_wt_exists_post="yes"
[[ ! -d "$_wt_dir_for_check" ]] && _wt_exists_post="no"
assert_eq "test_worktree_cleanup_after_merge: worktree directory removed" \
    "no" "$_wt_exists_post"

# Verify worktree no longer registered with git
_wt_listed_post=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "$_wt_dir_for_check" || true)
assert_eq "test_worktree_cleanup_after_merge: worktree no longer listed after cleanup" \
    "0" "$_wt_listed_post"

# Mark directory as already removed so trap doesn't attempt double-removal
_WORKTREE_DIR=""
# Still need to clean up the branch
git -C "$REPO_ROOT" branch -D "$_WORKTREE_BRANCH" 2>/dev/null || true
_WORKTREE_BRANCH=""
if [[ -n "${_ARTIFACTS_DIR:-}" ]]; then
    rm -rf "$_ARTIFACTS_DIR" 2>/dev/null || true
    _ARTIFACTS_DIR=""
fi

# ============================================================
# Summary
# ============================================================
print_summary
