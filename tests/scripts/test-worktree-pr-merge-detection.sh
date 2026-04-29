#!/usr/bin/env bash
# tests/scripts/test-worktree-pr-merge-detection.sh
# RED test for bug 8dc7-baa8: is_branch_merged fails to detect branches merged
# via a GitHub Pull Request squash merge.
#
# Bug: When a feature branch is merged into main via a GitHub PR squash merge
# (the branch commits are NOT ancestors of main), is_branch_merged returns 1
# because:
#   1. git merge-base --is-ancestor fails (squash commit has different SHA)
#   2. git log --grep="(merge $branch)" finds nothing (GitHub uses a different
#      commit message format: "Merge pull request #N from org/branch-name")
#
# Fix (not yet applied): A third fallback will search for the branch name in
# merge commit messages without the parenthetical constraint, matching GitHub's
# PR merge commit format.
#
# Observable behavior under test:
#   worktree-cleanup.sh --dry-run should output "would remove" for a worktree
#   whose branch was squash-merged via a GitHub PR.
#
# RED state: output shows "keep (not merged)" — is_branch_merged returns 1
# GREEN state: output shows "would remove" — is_branch_merged returns 0
#
# Usage: bash tests/scripts/test-worktree-pr-merge-detection.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/assert.sh"

CLEANUP_SCRIPT="$REPO_ROOT/plugins/dso/scripts/worktree-cleanup.sh"

echo "=== test-worktree-pr-merge-detection.sh ==="

# ── Temp dir management ───────────────────────────────────────────────────────

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
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

# ── Helper: set up repo with a GitHub-style PR squash merge ──────────────────
#
# Creates:
#   - A bare "origin" repo
#   - A "main" clone with initial commit
#   - A feature branch with one commit
#   - A worktree on that feature branch
#   - On main: a new squash commit (does NOT include feature branch tip as ancestor)
#     with commit message "Merge pull request #42 from navapbc/<branch-name>"
#
# The feature branch tip is NOT an ancestor of main (squash merge scenario).
# The only way to detect the merge is by finding the branch name in the PR
# commit message on main.
#
# Outputs (one per line):
#   $1: path to main repo clone
#   $2: path to worktree
#   $3: feature branch name
#
# Sets MAIN_REPO as a side-effect for use with the cleanup script.
_setup_github_pr_squash_merge() {
    local tmp="$1"
    local branch_name="${2:-worktree-test}"

    # Create bare origin
    git init --bare -b main -q "$tmp/origin.git"

    # Clone into main repo
    git clone -q "$tmp/origin.git" "$tmp/main-repo" 2>/dev/null
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > file.txt
        git add file.txt
        git commit -q -m "initial commit"
        git push -q origin main 2>/dev/null
    )

    # Create the feature branch (from main, not checked out)
    git -C "$tmp/main-repo" branch -q "$branch_name"

    # Create the worktree directory for the feature branch
    local wt_dir="$tmp/worktrees"
    mkdir -p "$wt_dir"
    local wt_path="$wt_dir/$branch_name"

    # Add worktree for the feature branch (worktree checks out the branch)
    git -C "$tmp/main-repo" worktree add "$wt_path" "$branch_name" -q

    # Add commits to the feature branch via its worktree
    (
        cd "$wt_path" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "feature work" > feature.txt
        git add feature.txt
        git commit -q -m "feat: add feature work"
        echo "more feature" >> feature.txt
        git add feature.txt
        git commit -q -m "feat: refine feature"
    )

    # === Simulate GitHub squash merge ===
    # On main, create a NEW commit (squash) that does NOT include
    # the feature branch tip as an ancestor. This mimics a GitHub PR squash merge.
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        # Create a squash commit: apply the same change but as a single new commit
        # whose parent is main (NOT a merge commit that includes the branch tip).
        echo "squashed feature content" > squashed-feature.txt
        git add squashed-feature.txt
        # Commit message matches GitHub PR merge format exactly
        git commit -q -m "Merge pull request #42 from navapbc/$branch_name"
        git push -q origin main 2>/dev/null
    )

    # Verify the feature branch tip is NOT an ancestor of main (confirms squash)
    # If this check fails, the test setup is wrong — not a squash scenario.
    if git -C "$tmp/main-repo" merge-base --is-ancestor "$branch_name" main 2>/dev/null; then
        echo "TEST SETUP ERROR: feature branch tip IS an ancestor of main — squash simulation failed" >&2
        exit 2
    fi

    MAIN_REPO="$tmp/main-repo"
    echo "$MAIN_REPO"
    echo "$wt_path"
    echo "$branch_name"
}

# ── test_github_pr_squash_merge_detected_as_merged ───────────────────────────
# When a feature branch is squash-merged via a GitHub PR, the worktree-cleanup
# --dry-run should mark the worktree as "would remove" (merged detected).
# RED state: is_branch_merged returns 1, dry-run shows "keep (not merged)".
# GREEN state: is_branch_merged returns 0, dry-run shows "would remove".
test_github_pr_squash_merge_detected_as_merged() {
    local tmp
    tmp=$(make_tmpdir)

    local branch_name="worktree-20260429-github-pr-test"

    local main_repo wt_path wt_branch
    read -r main_repo wt_path wt_branch <<< "$(_setup_github_pr_squash_merge "$tmp" "$branch_name" | tr '\n' ' ')"

    # Run the cleanup script from inside the main repo.
    # AGE_HOURS=0 bypasses the age gate so only the merged-detection gate matters.
    # NON_INTERACTIVE=true prevents prompts in dry-run mode.
    local output
    output=$(
        cd "$main_repo" && \
        AGE_HOURS=0 \
        NON_INTERACTIVE=true \
        bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null
    ) || true

    # After the fix, the PR squash-merged branch MUST be detected as merged
    # and the dry-run output MUST say "would remove".
    # In the RED state (before the fix), the output says "keep (not merged)"
    # and this assertion FAILS.
    assert_contains \
        "github_pr_squash_merge: dry-run detects branch as merged and would remove worktree" \
        "would remove" \
        "$output"

    # Confirm the branch name appears in the dry-run output (sanity check that
    # the worktree was scanned at all).
    assert_contains \
        "github_pr_squash_merge: worktree branch appears in dry-run listing" \
        "$branch_name" \
        "$output"

    echo "test_github_pr_squash_merge_detected_as_merged ... PASS"
}

# ── test_unrelated_branch_name_mention_not_false_positive ────────────────────
# A branch whose name appears in an unrelated commit message (NOT a PR merge)
# must NOT be falsely classified as merged. Protects against substring-match
# false positives that would cause premature auto-deletion of live worktrees.
test_unrelated_branch_name_mention_not_false_positive() {
    local tmp
    tmp=$(make_tmpdir)

    local branch_name="worktree-20260429-active-branch"

    # Set up repo with the feature branch and an unrelated commit on main
    # whose message MENTIONS the branch name but is NOT a GitHub PR merge.
    git init --bare -b main -q "$tmp/origin.git"
    git clone -q "$tmp/origin.git" "$tmp/main-repo" 2>/dev/null
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > file.txt
        git add file.txt && git commit -q -m "initial commit"
        git push -q origin main 2>/dev/null
    )

    git -C "$tmp/main-repo" branch -q "$branch_name"
    local wt_dir="$tmp/worktrees"
    mkdir -p "$wt_dir"
    local wt_path="$wt_dir/$branch_name"
    git -C "$tmp/main-repo" worktree add "$wt_path" "$branch_name" -q

    (
        cd "$wt_path" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "in-progress work" > work.txt
        git add work.txt && git commit -q -m "wip: in progress"
    )

    # Add a commit on main whose message mentions the branch name but is NOT
    # a GitHub PR merge commit. This simulates e.g. a revert or a note commit.
    (
        cd "$tmp/main-repo" || exit
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "other" > other.txt
        git add other.txt
        git commit -q -m "chore: tracked $branch_name in backlog"
        git push -q origin main 2>/dev/null
    )

    local output
    output=$(
        cd "$tmp/main-repo" && \
        AGE_HOURS=0 \
        NON_INTERACTIVE=true \
        bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null
    ) || true

    # The branch is NOT merged via a GitHub PR, so it must NOT be marked for removal.
    assert_not_contains \
        "unrelated_mention: branch name in unrelated commit does not cause false positive removal" \
        "would remove" \
        "$output"
}

# ── test_github_pr_merge_detected_in_claude_safe ─────────────────────────────
# _offer_worktree_cleanup in claude-safe must also detect a GitHub PR merge.
test_github_pr_merge_detected_in_claude_safe() {
    local tmp
    tmp=$(make_tmpdir)

    # Resolve python with pyyaml for read-config.sh
    REPO_ROOT_LOCAL="$(git rev-parse --show-toplevel)"
    local plugin_python=""
    for _cand in "$REPO_ROOT_LOCAL/app/.venv/bin/python3" "$REPO_ROOT_LOCAL/.venv/bin/python3" python3; do
        [[ "$_cand" != "python3" ]] && [[ ! -f "$_cand" ]] && continue
        if "$_cand" -c "import yaml" 2>/dev/null; then plugin_python="$_cand"; break; fi
    done
    if [[ -z "$plugin_python" ]]; then
        echo "SKIP: no python3 with pyyaml — skipping claude-safe test" >&2
        _snapshot_fail; assert_pass_if_clean "test_github_pr_merge_detected_in_claude_safe_skipped"
        return
    fi

    local branch_name="worktree-20260429-claude-safe-pr-test"
    local main_repo wt_path _branch
    read -r main_repo wt_path _branch <<< "$(_setup_github_pr_squash_merge "$tmp" "$branch_name" | tr '\n' ' ')"

    local CLAUDE_SAFE="$REPO_ROOT_LOCAL/plugins/dso/scripts/claude-safe"
    local PLUGIN_SCRIPTS="$REPO_ROOT_LOCAL/plugins/dso/scripts"

    local output
    output=$(
        _CLAUDE_SAFE_SOURCE_ONLY=1 \
        _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
        PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
        CLAUDE_PLUGIN_PYTHON="$plugin_python" \
        bash -c "source \"$CLAUDE_SAFE\"; _offer_worktree_cleanup '$branch_name' '$wt_path'"
    ) 2>&1 || true

    assert_contains \
        "claude_safe_pr_merge: _offer_worktree_cleanup detects GitHub PR merge and auto-removes" \
        "Cleaning up" \
        "$output"
}

# ── Run tests ─────────────────────────────────────────────────────────────────

echo ""
echo "--- test_github_pr_squash_merge_detected_as_merged ---"
_snapshot_fail
test_github_pr_squash_merge_detected_as_merged
assert_pass_if_clean "test_github_pr_squash_merge_detected_as_merged"

echo ""
echo "--- test_unrelated_branch_name_mention_not_false_positive ---"
_snapshot_fail
test_unrelated_branch_name_mention_not_false_positive
assert_pass_if_clean "test_unrelated_branch_name_mention_not_false_positive"

echo ""
echo "--- test_github_pr_merge_detected_in_claude_safe ---"
_snapshot_fail
test_github_pr_merge_detected_in_claude_safe
assert_pass_if_clean "test_github_pr_merge_detected_in_claude_safe"

print_summary
