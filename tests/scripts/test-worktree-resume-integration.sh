#!/usr/bin/env bash
# tests/scripts/test-worktree-resume-integration.sh
# Integration tests for plugins/dso/scripts/resolve-abandoned-worktrees.sh
#
# Tests use real git repos in temp dirs.
# These tests are RED until resolve-abandoned-worktrees.sh is implemented.
#
# Usage: bash tests/scripts/test-worktree-resume-integration.sh
#
# Tests:
#   1. test_resume_merges_unique_branch     — branch with unique commit gets merged
#   2. test_resume_discards_already_merged_branch — already-merged branch is skipped (no re-merge)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
RESOLVE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/resolve-abandoned-worktrees.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== test-worktree-resume-integration.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# Create a minimal git repo with git identity configured.
# Usage: init_git_repo <dir>
init_git_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    # Initial commit so HEAD exists
    git -C "$dir" commit -q --allow-empty -m "initial commit"
}

# ── Test 1: test_resume_merges_unique_branch ─────────────────────────────────
# Setup: real git repo with a branch containing a unique commit not reachable
#        from main, and a WORKTREE_TRACKING:start comment in a tracked file.
# Expected: resolve-abandoned-worktrees.sh merges the branch into the session
#           branch. Tests are RED because the script doesn't exist yet.

echo ""
echo "--- test_resume_merges_unique_branch ---"
_snapshot_fail

_run_test_resume_merges_unique_branch() {
    # Script must exist — RED until implemented
    if [[ ! -f "$RESOLVE_SCRIPT" ]]; then
        assert_eq "resolve-abandoned-worktrees.sh exists" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(make_tmpdir)
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Create a session branch
    git -C "$repo" checkout -q -b session-branch

    # Create the abandoned feature branch from the same base
    git -C "$repo" checkout -q -b abandoned-feature-branch

    # Add a unique commit (not reachable from session-branch)
    echo "# WORKTREE_TRACKING:start" > "$repo/tracked-file.txt"
    echo "feature work" >> "$repo/tracked-file.txt"
    git -C "$repo" add tracked-file.txt
    git -C "$repo" commit -q -m "feat: unique commit on abandoned branch"

    local unique_sha
    unique_sha=$(git -C "$repo" rev-parse HEAD)

    # Switch back to session-branch; unique_sha is NOT reachable from here
    git -C "$repo" checkout -q session-branch

    # Invoke the resolver — it should detect the abandoned branch and merge it
    local output exit_code
    output=$(bash "$RESOLVE_SCRIPT" --repo "$repo" --session-branch session-branch 2>&1) || exit_code=$?
    exit_code="${exit_code:-0}"

    # After resolution, the unique commit should be reachable from session-branch
    if git -C "$repo" merge-base --is-ancestor "$unique_sha" HEAD 2>/dev/null; then
        assert_eq "unique commit merged into session-branch" "true" "true"
    else
        assert_eq "unique commit merged into session-branch" "true" "false"
    fi
}

_run_test_resume_merges_unique_branch
assert_pass_if_clean "test_resume_merges_unique_branch"

# ── Test 2: test_resume_discards_already_merged_branch ───────────────────────
# Setup: a branch that is already an ancestor of the session branch HEAD.
# Expected: resolve-abandoned-worktrees.sh skips re-merging it (no new commit,
#           no error). Tests are RED because the script doesn't exist yet.

echo ""
echo "--- test_resume_discards_already_merged_branch ---"
_snapshot_fail

_run_test_resume_discards_already_merged_branch() {
    # Script must exist — RED until implemented
    if [[ ! -f "$RESOLVE_SCRIPT" ]]; then
        assert_eq "resolve-abandoned-worktrees.sh exists" "exists" "missing"
        return
    fi

    local tmpdir
    tmpdir=$(make_tmpdir)
    local repo="$tmpdir/repo"
    mkdir -p "$repo"
    init_git_repo "$repo"

    # Create the feature branch with a commit
    git -C "$repo" checkout -q -b already-merged-branch
    echo "already merged content" > "$repo/merged-file.txt"
    git -C "$repo" add merged-file.txt
    git -C "$repo" commit -q -m "feat: commit that will be merged"

    # Create session-branch by merging already-merged-branch in (so it IS an ancestor)
    git -C "$repo" checkout -q -b session-branch
    git -C "$repo" merge -q --no-ff already-merged-branch -m "merge already-merged-branch"

    local commit_count_before
    commit_count_before=$(git -C "$repo" rev-list --count HEAD)

    # Invoke the resolver — it should detect the branch is already an ancestor and skip
    local output exit_code
    output=$(bash "$RESOLVE_SCRIPT" --repo "$repo" --session-branch session-branch 2>&1) || exit_code=$?
    exit_code="${exit_code:-0}"

    local commit_count_after
    commit_count_after=$(git -C "$repo" rev-list --count HEAD)

    # No new merge commit should have been added
    assert_eq "no new commit added for already-merged branch" \
        "$commit_count_before" "$commit_count_after"
}

_run_test_resume_discards_already_merged_branch
assert_pass_if_clean "test_resume_discards_already_merged_branch"

# ── Summary ───────────────────────────────────────────────────────────────────

print_summary
