#!/usr/bin/env bash
# tests/scripts/test-claude-safe-post-merge-amend.sh
# Tests that _offer_worktree_cleanup correctly detects merged branches even when
# the worktree branch tip was amended after merge-to-main.sh merged it into main.
#
# Bug: When merge-to-main.sh times out (~73s ceiling), the orchestrator may
# amend the sync merge commit on the worktree branch during recovery. This
# changes the branch tip SHA so it's no longer the commit that main merged.
# _offer_worktree_cleanup's `merge-base --is-ancestor` check then fails,
# reporting "cannot be auto-removed" even though the branch's work is on main.
#
# Usage: bash tests/scripts/test-claude-safe-post-merge-amend.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
CLAUDE_SAFE="$DSO_PLUGIN_DIR/scripts/claude-safe"
PLUGIN_SCRIPTS="$DSO_PLUGIN_DIR/scripts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-claude-safe-post-merge-amend.sh ==="

TMPDIR_BASE=$(mktemp -d /tmp/test-claude-safe-post-merge-amend.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Resolve Python with pyyaml for read-config.sh ────────────────────────────
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_PYTHON=""
for _candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_candidate" ]] && continue
    [[ "$_candidate" != "python3" ]] && [[ ! -f "$_candidate" ]] && continue
    if "$_candidate" -c "import yaml" 2>/dev/null; then
        PLUGIN_PYTHON="$_candidate"
        break
    fi
done
if [[ -z "$PLUGIN_PYTHON" ]]; then
    echo "SKIP: no python3 with pyyaml found" >&2
    exit 0
fi

# ── Helper: set up a main repo + origin + worktree, do work, sync-merge, and
#    merge to main — reproducing the exact merge-to-main.sh flow ──────────────
_setup_merged_worktree() {
    local origin="$TMPDIR_BASE/origin.git"
    local main_repo="$TMPDIR_BASE/main-repo"
    local wt_dir="$TMPDIR_BASE/worktrees"
    local wt_name="worktree-test"
    local wt_path="$wt_dir/$wt_name"

    # Create origin + main repo
    git init --bare -q "$origin"
    git clone -q "$origin" "$main_repo" 2>/dev/null
    (
        cd "$main_repo"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > file.txt
        git add file.txt && git commit -q -m "initial commit"
        git push -q origin main 2>/dev/null
    )

    # Create worktree
    mkdir -p "$wt_dir"
    git -C "$main_repo" worktree add "$wt_path" -b "$wt_name" -q

    # Work on worktree
    (
        cd "$wt_path"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "feature" > feature.txt
        git add feature.txt && git commit -q -m "feat: add feature"
    )

    # Simulate other work landing on origin/main (triggers sync merge)
    (
        cd "$main_repo"
        git checkout -q main
        echo "other" > other.txt
        git add other.txt && git commit -q -m "feat: other work"
        git push -q origin main 2>/dev/null
    )

    # === Reproduce merge-to-main.sh sequence ===
    # _phase_sync: worktree merges origin/main (creates sync merge commit)
    (
        cd "$wt_path"
        git fetch origin main -q 2>/dev/null
        git merge origin/main --no-edit -q
    )

    # _phase_sync: main pulls
    (
        cd "$main_repo"
        git checkout -q main
        git pull --rebase -q 2>/dev/null
    )

    # _phase_merge: merge worktree branch into main (--no-ff)
    git -C "$main_repo" merge --no-ff "$wt_name" -m "feat: work (merge $wt_name)" -q

    # _phase_push
    git -C "$main_repo" push -q origin main 2>/dev/null

    # Export paths for test use
    echo "$main_repo"
    echo "$wt_path"
    echo "$wt_name"
}

# ── test_normal_merge_detected ───────────────────────────────────────────────
# Baseline: without any post-merge amend, the branch IS detected as merged
# and _offer_worktree_cleanup auto-removes it (output says "Cleaning up").
echo ""
echo "--- test_normal_merge_detected ---"
_snapshot_fail

# Fresh setup
rm -rf "$TMPDIR_BASE/origin.git" "$TMPDIR_BASE/main-repo" "$TMPDIR_BASE/worktrees"
read -r _main_repo _wt_path _wt_name <<< "$(_setup_merged_worktree | tr '\n' ' ')"

_output=""
_output=$(
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash -c "source \"$CLAUDE_SAFE\"; _offer_worktree_cleanup '$_wt_name' '$_wt_path'"
) 2>&1 || true

assert_contains "test_normal_merge_detected: auto-removes merged branch" \
    "Cleaning up" "$_output"
assert_pass_if_clean "test_normal_merge_detected"

# ── test_post_merge_amend_detected_as_merged ─────────────────────────────────
# Bug reproduction: after the merge to main, amend the worktree branch's HEAD
# (simulating what the orchestrator does after a merge-to-main.sh timeout).
# The amended commit has a different SHA than what main merged, so the naive
# merge-base --is-ancestor check fails. The fix should detect this and still
# auto-remove the worktree.
echo ""
echo "--- test_post_merge_amend_detected_as_merged ---"
_snapshot_fail

# Fresh setup
rm -rf "$TMPDIR_BASE/origin.git" "$TMPDIR_BASE/main-repo" "$TMPDIR_BASE/worktrees"
read -r _main_repo _wt_path _wt_name <<< "$(_setup_merged_worktree | tr '\n' ' ')"

# Simulate the orchestrator amending the worktree branch after timeout
(
    cd "$_wt_path"
    # Touch a file and amend (simulates ruff format + git commit --amend)
    echo "# amended" >> feature.txt
    git add feature.txt
    git commit --amend --no-edit -q
)

# Verify the bug condition: branch tip is NOT an ancestor of main
_is_ancestor=0
_main_root=$(git -C "$_wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
git -C "$_main_root" merge-base --is-ancestor "$_wt_name" main 2>/dev/null && _is_ancestor=1
assert_eq "precondition: amended branch tip is NOT ancestor of main" "0" "$_is_ancestor"

# Now test _offer_worktree_cleanup — it should STILL detect the branch as merged
# because main has a merge commit referencing this branch
_output2=""
_output2=$(
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash -c "source \"$CLAUDE_SAFE\"; _offer_worktree_cleanup '$_wt_name' '$_wt_path'"
) 2>&1 || true

# The fix should make this say "Cleaning up" instead of "cannot be auto-removed"
assert_contains "test_post_merge_amend_detected_as_merged: auto-removes despite amend" \
    "Cleaning up" "$_output2"
assert_pass_if_clean "test_post_merge_amend_detected_as_merged"

# ── test_genuinely_unmerged_branch_still_blocked ─────────────────────────────
# A branch that was never merged to main should still be blocked.
echo ""
echo "--- test_genuinely_unmerged_branch_still_blocked ---"
_snapshot_fail

_unmerged_main="$TMPDIR_BASE/unmerged-main"
_unmerged_wt="$TMPDIR_BASE/unmerged-wt"
_unmerged_origin="$TMPDIR_BASE/unmerged-origin.git"

git init --bare -q "$_unmerged_origin"
git clone -q "$_unmerged_origin" "$_unmerged_main" 2>/dev/null
(
    cd "$_unmerged_main"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > file.txt
    git add file.txt && git commit -q -m "initial commit"
    git push -q origin main 2>/dev/null
)
git -C "$_unmerged_main" worktree add "$_unmerged_wt" -b "unmerged-branch" -q
(
    cd "$_unmerged_wt"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "unmerged work" > unmerged.txt
    git add unmerged.txt && git commit -q -m "feat: unmerged work"
)

_output3=""
_output3=$(
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash -c "source \"$CLAUDE_SAFE\"; _offer_worktree_cleanup 'unmerged-branch' '$_unmerged_wt'"
) 2>&1 || true

assert_contains "test_genuinely_unmerged_branch_still_blocked: blocks unmerged branch" \
    "cannot be auto-removed" "$_output3"
assert_pass_if_clean "test_genuinely_unmerged_branch_still_blocked"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
