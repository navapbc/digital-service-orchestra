#!/usr/bin/env bash
# Tests worktree isolation properties — verifies that git worktrees produce
# distinct REPO_ROOT values and distinct ARTIFACTS_DIR paths.
#
# This is a spike task: the test file IS the deliverable. It validates existing
# framework behavior (git worktree mechanics + get_artifacts_dir hashing).
#
# Tests:
#   test_worktree_git_root_differs
#   test_artifacts_dir_differs_for_worktree
#   test_worktree_cleanup
#
# Usage: bash tests/hooks/test-worktree-isolation-verification.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Shared state for worktree lifecycle
_WORKTREE_DIR=""
_WORKTREE_BRANCH="test-worktree-isolation-$$"

# Helper: create a temporary worktree for testing
setup_worktree() {
    _WORKTREE_DIR=$(mktemp -d)
    # Resolve symlinks (macOS /var -> /private/var) for consistent comparison
    _WORKTREE_DIR=$(cd "$_WORKTREE_DIR" && pwd -P)
    # Create an orphan branch so we don't interfere with real branches
    git -C "$REPO_ROOT" worktree add -b "$_WORKTREE_BRANCH" "$_WORKTREE_DIR" HEAD 2>/dev/null
}

# Helper: remove the temporary worktree
teardown_worktree() {
    if [[ -n "$_WORKTREE_DIR" && -d "$_WORKTREE_DIR" ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$_WORKTREE_DIR" 2>/dev/null || true
    fi
    # Clean up the temporary branch
    git -C "$REPO_ROOT" branch -D "$_WORKTREE_BRANCH" 2>/dev/null || true
}

# Ensure cleanup on exit
trap teardown_worktree EXIT

# ============================================================
# test_worktree_git_root_differs
# A git worktree in a different directory must report a different
# git rev-parse --show-toplevel than the parent repo.
# ============================================================
echo "--- test_worktree_git_root_differs ---"
setup_worktree

_parent_root="$REPO_ROOT"
_worktree_root=$(git -C "$_WORKTREE_DIR" rev-parse --show-toplevel 2>/dev/null)
# Resolve symlinks for consistent comparison (macOS /var -> /private/var)
_worktree_root=$(cd "$_worktree_root" && pwd -P)

assert_ne "test_worktree_git_root_differs: worktree root differs from parent" \
    "$_parent_root" "$_worktree_root"

assert_eq "test_worktree_git_root_differs: worktree root matches temp dir" \
    "$_WORKTREE_DIR" "$_worktree_root"

# ============================================================
# test_artifacts_dir_differs_for_worktree
# get_artifacts_dir() must produce a different path when REPO_ROOT
# points to the worktree vs. the parent repo, because the hash
# of REPO_ROOT will differ.
# ============================================================
echo "--- test_artifacts_dir_differs_for_worktree ---"

# Reset the deps guard so we can source it fresh with different REPO_ROOT
unset _DEPS_LOADED

# Get artifacts dir for parent repo
source "$PLUGIN_ROOT/plugins/dso/hooks/lib/deps.sh"
_parent_artifacts=$(REPO_ROOT="$_parent_root" get_artifacts_dir)

# Reset deps guard for second call
unset _DEPS_LOADED

# Get artifacts dir for worktree
_worktree_artifacts=$(REPO_ROOT="$_worktree_root" get_artifacts_dir)

assert_ne "test_artifacts_dir_differs_for_worktree: artifacts dirs differ" \
    "$_parent_artifacts" "$_worktree_artifacts"

# Verify both are under /tmp/workflow-plugin-
assert_contains "test_artifacts_dir_differs_for_worktree: parent uses workflow-plugin prefix" \
    "/tmp/workflow-plugin-" "$_parent_artifacts"

assert_contains "test_artifacts_dir_differs_for_worktree: worktree uses workflow-plugin prefix" \
    "/tmp/workflow-plugin-" "$_worktree_artifacts"

# ============================================================
# test_worktree_cleanup
# git worktree remove must cleanly remove the worktree directory.
# ============================================================
echo "--- test_worktree_cleanup ---"

# Verify worktree exists before removal
_exists_before="no"
[[ -d "$_WORKTREE_DIR" ]] && _exists_before="yes"
assert_eq "test_worktree_cleanup: worktree exists before removal" "yes" "$_exists_before"

# Verify worktree is listed
_listed=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "$_WORKTREE_DIR" || true)
assert_eq "test_worktree_cleanup: worktree is listed" "1" "$_listed"

# Remove worktree
git -C "$REPO_ROOT" worktree remove --force "$_WORKTREE_DIR" 2>/dev/null
_remove_exit=$?
assert_eq "test_worktree_cleanup: remove exits 0" "0" "$_remove_exit"

# Verify directory is gone
_exists_after="yes"
[[ ! -d "$_WORKTREE_DIR" ]] && _exists_after="no"
assert_eq "test_worktree_cleanup: directory removed" "no" "$_exists_after"

# Verify worktree is no longer listed
_listed_after=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | grep -c "$_WORKTREE_DIR" || true)
assert_eq "test_worktree_cleanup: worktree no longer listed" "0" "$_listed_after"

# Mark as cleaned up so trap doesn't try again
_WORKTREE_DIR=""

# Clean up the branch
git -C "$REPO_ROOT" branch -D "$_WORKTREE_BRANCH" 2>/dev/null || true

# ============================================================
# Summary
# ============================================================
print_summary
