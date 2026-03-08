#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-hook-fallback.sh
# Tests that the PostToolUse hook (ticket-sync-push.sh) degrades gracefully
# when tk-sync-lib.sh cannot be loaded.
#
# The hook sources tk-sync-lib.sh via:
#   source "$_HOOK_REPO_ROOT/scripts/tk-sync-lib.sh" 2>/dev/null || true
# When this fails, _sync_ticket_file is not defined, so the declare -f check
# falls through to the fallback branch which logs a warning and exits 0.
#
# Usage: bash lockpick-workflow/tests/hooks/test-hook-fallback.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_ORIG="$REPO_ROOT/lockpick-workflow/hooks/ticket-sync-push.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# After the tk CLI migration, the hook resolves tk-sync-lib.sh via its own
# HOOK_DIR (sibling scripts/ dir within the plugin), so the fallback code path
# is never reached when using the original hook. To exercise the fallback, we
# copy the hook and its lib/ dependency into a temp dir whose sibling scripts/
# does NOT contain tk-sync-lib.sh. This makes the HOOK_DIR/../scripts/ check
# fail and $_HOOK_REPO_ROOT (temp worktree) also lacks it, triggering fallback.
_HOOK_TEMP_DIR=$(mktemp -d)
mkdir -p "$_HOOK_TEMP_DIR/hooks/lib"
cp "$HOOK_ORIG" "$_HOOK_TEMP_DIR/hooks/ticket-sync-push.sh"
cp "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh" "$_HOOK_TEMP_DIR/hooks/lib/deps.sh"
chmod +x "$_HOOK_TEMP_DIR/hooks/ticket-sync-push.sh"
HOOK="$_HOOK_TEMP_DIR/hooks/ticket-sync-push.sh"
trap 'rm -rf "$_HOOK_TEMP_DIR"' EXIT

# --------------------------------------------------------------------------
# Setup: create a minimal worktree environment so the hook reaches the
# fallback code path (past the .git-is-a-file and file-exists guards).
# --------------------------------------------------------------------------
setup_worktree_env() {
    local main_repo
    main_repo=$(mktemp -d)
    local worktree_dir
    worktree_dir=$(mktemp -d)

    # Create a minimal main repo with an initial commit
    git -C "$main_repo" init -q -b main
    git -C "$main_repo" config user.email "test@test.com"
    git -C "$main_repo" config user.name "Test"
    git -C "$main_repo" commit --allow-empty -q -m "init"

    # Create a worktree (.git is a FILE pointing to main repo)
    git -C "$main_repo" worktree add -q "$worktree_dir" HEAD 2>/dev/null

    # Create a ticket file so the hook's file-exists guard passes
    mkdir -p "$worktree_dir/.tickets"
    echo "---" > "$worktree_dir/.tickets/test-fallback.md"

    echo "$main_repo" "$worktree_dir"
}

cleanup_worktree_env() {
    local main_repo="$1" worktree_dir="$2"
    git -C "$main_repo" worktree remove --force "$worktree_dir" 2>/dev/null || true
    rm -rf "$main_repo" "$worktree_dir"
}

# --------------------------------------------------------------------------
# test_hook_fallback_exits_zero_when_lib_missing
# When tk-sync-lib.sh cannot be loaded, the hook should still exit 0.
# --------------------------------------------------------------------------
read -r MAIN_REPO WORKTREE_DIR <<< "$(setup_worktree_env)"

INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$WORKTREE_DIR"'/.tickets/test-fallback.md"},"tool_response":{"success":true}}'

# Run the hook from INSIDE the temp worktree so that git rev-parse
# --show-toplevel resolves to the temp worktree dir (which has no
# scripts/tk-sync-lib.sh). This causes the source on line 33 of the hook
# to fail, leaving _sync_ticket_file undefined and triggering the fallback.
RESULT=$(cd "$WORKTREE_DIR" && echo "$INPUT" | bash "$HOOK" 2>/tmp/test-hook-fallback-stderr; echo "EXIT:$?")
EXIT_CODE="${RESULT##*EXIT:}"
STDERR_OUTPUT=$(cat /tmp/test-hook-fallback-stderr)

assert_eq "test_hook_fallback_exits_zero_when_lib_missing" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_hook_fallback_warns_on_stderr_when_lib_missing
# The hook should emit a warning to stderr mentioning the lib is not loaded.
# --------------------------------------------------------------------------
assert_contains "test_hook_fallback_warns_on_stderr_when_lib_missing" \
    "tk-sync-lib.sh not loaded" "$STDERR_OUTPUT"

# --------------------------------------------------------------------------
# test_hook_fallback_warns_with_filename_on_stderr
# The warning should include the basename of the file being synced.
# --------------------------------------------------------------------------
assert_contains "test_hook_fallback_warns_with_filename_on_stderr" \
    "test-fallback.md" "$STDERR_OUTPUT"

cleanup_worktree_env "$MAIN_REPO" "$WORKTREE_DIR"
rm -f /tmp/test-hook-fallback-stderr

# --------------------------------------------------------------------------
print_summary
