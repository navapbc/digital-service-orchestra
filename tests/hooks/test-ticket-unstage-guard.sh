#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-ticket-unstage-guard.sh
# Tests for scripts/pre-commit-ticket-unstage-guard.sh
#
# Pre-commit hook that detects .tickets/ files staged on non-main branches,
# automatically unstages them (git reset HEAD .tickets/), prints a warning,
# and allows the commit to proceed with remaining staged files.
#
# Test coverage:
#   1.  bash -n syntax check — structural, always passes
#   2.  no-op on main branch (exits 0, does NOT unstage)
#   3.  no-op when no .tickets/ files staged
#   4.  unstages .tickets/ files on a non-main branch
#   5.  exits 0 (allows commit to proceed) after unstaging
#   6.  warning message mentions the unstaged files
#   7.  warning message explains ticket sync mechanism
#   8.  only unstages .tickets/ files (not other staged files)
#   9.  hook is registered in .pre-commit-config.yaml
#
# Usage: bash lockpick-workflow/tests/hooks/test-ticket-unstage-guard.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/pre-commit-ticket-unstage-guard.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-ticket-unstage-guard.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: make_git_repo_with_branch
# Creates an isolated git repo with a named branch and optional staged files.
# Returns: TMPDIR path
#
# Args:
#   $1 — branch name (use "main" for main branch)
#   $2 — "stage_tickets" to stage a .tickets/ file (optional)
#   $3 — "stage_other" to also stage a non-tickets file (optional)
# ---------------------------------------------------------------------------
make_git_repo_with_branch() {
    local branch_name="$1"
    local stage_tickets="${2:-}"
    local stage_other="${3:-}"

    local tmpdir
    tmpdir=$(mktemp -d)

    # Initialize bare git repo with a main branch
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    # Create initial commit on main
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"

    # Rename default branch to 'main' if not already
    local current_branch
    current_branch=$(git -C "$tmpdir" rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "main" ]]; then
        git -C "$tmpdir" branch -m "$current_branch" main
    fi

    # Switch to the requested branch (create if not main)
    if [[ "$branch_name" != "main" ]]; then
        git -C "$tmpdir" checkout -q -b "$branch_name"
    fi

    # Optionally stage a .tickets/ file
    if [[ "$stage_tickets" == "stage_tickets" ]]; then
        mkdir -p "$tmpdir/.tickets"
        echo "---" > "$tmpdir/.tickets/test-ticket.md"
        git -C "$tmpdir" add ".tickets/test-ticket.md"
    fi

    # Optionally stage a non-tickets file
    if [[ "$stage_other" == "stage_other" ]]; then
        echo "code change" > "$tmpdir/app.py"
        git -C "$tmpdir" add app.py
    fi

    echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 1: bash -n syntax check — structural test, always passes
# ---------------------------------------------------------------------------
echo "Test 1: pre-commit-ticket-unstage-guard.sh has no bash syntax errors"
syntax_exit=0
bash -n "$HOOK" 2>&1 || syntax_exit=$?
assert_eq "test_syntax_ok" "0" "$syntax_exit"

# ---------------------------------------------------------------------------
# Test 2: no-op on main branch — exits 0 without unstaging
# On main, ticket files are expected so hook should be transparent.
# ---------------------------------------------------------------------------
echo "Test 2: no-op on main branch"
_T2_DIR=$(make_git_repo_with_branch "main" "stage_tickets")
_T2_EXIT=0
_T2_OUTPUT=$(cd "$_T2_DIR" && bash "$HOOK" 2>&1) || _T2_EXIT=$?
# Staged file should still be in the index
_T2_STILL_STAGED=$(git -C "$_T2_DIR" diff --cached --name-only | grep -c "\.tickets/" 2>/dev/null; true)
assert_eq "test_main_branch_exits_0" "0" "$_T2_EXIT"
assert_eq "test_main_branch_does_not_unstage_tickets" "1" "$_T2_STILL_STAGED"
rm -rf "$_T2_DIR"

# ---------------------------------------------------------------------------
# Test 3: no-op when no .tickets/ files staged (non-main branch, clean index)
# Hook exits 0 without any output when there's nothing to unstage.
# ---------------------------------------------------------------------------
echo "Test 3: no-op when no .tickets/ files are staged"
_T3_DIR=$(make_git_repo_with_branch "feature/my-work" "" "")
_T3_EXIT=0
_T3_OUTPUT=$(cd "$_T3_DIR" && bash "$HOOK" 2>&1) || _T3_EXIT=$?
assert_eq "test_no_tickets_staged_exits_0" "0" "$_T3_EXIT"
rm -rf "$_T3_DIR"

# ---------------------------------------------------------------------------
# Test 4: unstages .tickets/ files on a non-main branch
# After hook runs, .tickets/ file should NOT be in the staged index.
# ---------------------------------------------------------------------------
echo "Test 4: unstages .tickets/ files on non-main branch"
_T4_DIR=$(make_git_repo_with_branch "worktree-feature" "stage_tickets")
# Verify tickets ARE staged before hook runs
_T4_STAGED_BEFORE=$(git -C "$_T4_DIR" diff --cached --name-only | grep -c "\.tickets/" 2>/dev/null; true)
assert_eq "test_tickets_staged_before_hook" "1" "$_T4_STAGED_BEFORE"
# Run the hook in a subshell to avoid polluting the CWD
_T4_EXIT=0
(cd "$_T4_DIR" && bash "$HOOK" >/dev/null 2>&1) || _T4_EXIT=$?
# Verify tickets are NOT staged after hook runs
_T4_STAGED_AFTER=$(git -C "$_T4_DIR" diff --cached --name-only | grep -c "\.tickets/" 2>/dev/null; true)
assert_eq "test_tickets_unstaged_after_hook" "0" "$_T4_STAGED_AFTER"
rm -rf "$_T4_DIR"

# ---------------------------------------------------------------------------
# Test 5: exits 0 on non-main branch even when tickets were found and unstaged
# The hook must NOT block the commit (return 0 even after unstaging).
# ---------------------------------------------------------------------------
echo "Test 5: exits 0 (allows commit) after unstaging tickets"
_T5_DIR=$(make_git_repo_with_branch "worktree-20260303-215800" "stage_tickets")
_T5_EXIT=0
(cd "$_T5_DIR" && bash "$HOOK" >/dev/null 2>&1) || _T5_EXIT=$?
assert_eq "test_exits_0_after_unstage" "0" "$_T5_EXIT"
rm -rf "$_T5_DIR"

# ---------------------------------------------------------------------------
# Test 6: warning message names the unstaged files
# When tickets are unstaged, the hook must print the filenames.
# ---------------------------------------------------------------------------
echo "Test 6: warning message names the unstaged files"
_T6_DIR=$(make_git_repo_with_branch "worktree-feature" "stage_tickets")
_T6_OUTPUT=""
_T6_EXIT=0
_T6_OUTPUT=$(cd "$_T6_DIR" && bash "$HOOK" 2>&1) || _T6_EXIT=$?
assert_contains "test_warning_names_file" "test-ticket.md" "$_T6_OUTPUT"
rm -rf "$_T6_DIR"

# ---------------------------------------------------------------------------
# Test 7: warning message explains ticket sync mechanism
# Must mention "sync" or "main" or "automatically" so developers understand why.
# ---------------------------------------------------------------------------
echo "Test 7: warning message mentions sync mechanism"
_T7_DIR=$(make_git_repo_with_branch "worktree-feature" "stage_tickets")
_T7_OUTPUT=""
_T7_EXIT=0
_T7_OUTPUT=$(cd "$_T7_DIR" && bash "$HOOK" 2>&1) || _T7_EXIT=$?
# Message should mention sync (the ticket sync mechanism)
_T7_HAS_SYNC=0
if echo "$_T7_OUTPUT" | grep -qiE "sync|main|automatically"; then
    _T7_HAS_SYNC=1
fi
assert_eq "test_warning_explains_sync" "1" "$_T7_HAS_SYNC"
rm -rf "$_T7_DIR"

# ---------------------------------------------------------------------------
# Test 8: only unstages .tickets/ files, not other staged files
# A non-tickets file staged alongside a ticket file must remain staged.
# ---------------------------------------------------------------------------
echo "Test 8: does not unstage non-tickets files"
_T8_DIR=$(make_git_repo_with_branch "worktree-feature" "stage_tickets" "stage_other")
# Verify both files are staged before hook
_T8_TICKETS_BEFORE=$(git -C "$_T8_DIR" diff --cached --name-only | grep -c "\.tickets/" 2>/dev/null; true)
_T8_OTHER_BEFORE=$(git -C "$_T8_DIR" diff --cached --name-only | grep -c "app.py" 2>/dev/null; true)
assert_eq "test_tickets_staged_before_t8" "1" "$_T8_TICKETS_BEFORE"
assert_eq "test_other_staged_before_t8" "1" "$_T8_OTHER_BEFORE"
# Run hook in a subshell to avoid polluting the CWD
(cd "$_T8_DIR" && bash "$HOOK" >/dev/null 2>&1) || true
# Verify tickets were unstaged
_T8_TICKETS_AFTER=$(git -C "$_T8_DIR" diff --cached --name-only | grep -c "\.tickets/" 2>/dev/null; true)
# Verify non-tickets file is still staged
_T8_OTHER_AFTER=$(git -C "$_T8_DIR" diff --cached --name-only | grep -c "app.py" 2>/dev/null; true)
assert_eq "test_tickets_unstaged_t8" "0" "$_T8_TICKETS_AFTER"
assert_eq "test_other_still_staged_t8" "1" "$_T8_OTHER_AFTER"
rm -rf "$_T8_DIR"

# ---------------------------------------------------------------------------
# Test 9: hook is registered in .pre-commit-config.yaml
# The hook must be integrated via the existing pre-commit infrastructure.
# ---------------------------------------------------------------------------
echo "Test 9: hook registered in .pre-commit-config.yaml"
PRECOMMIT_CONFIG="$REPO_ROOT/.pre-commit-config.yaml"
_T9_REGISTERED=0
if grep -q "ticket-unstage-guard\|pre-commit-ticket-unstage-guard" "$PRECOMMIT_CONFIG" 2>/dev/null; then
    _T9_REGISTERED=1
fi
assert_eq "test_hook_registered_in_precommit_config" "1" "$_T9_REGISTERED"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
