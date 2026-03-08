#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-sync-from-main-protection.sh
# Tests that _sync_from_main only runs before read subcommands and preserves
# local-only ticket changes that failed to push.
#
# Usage: bash lockpick-workflow/tests/hooks/test-sync-from-main-protection.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TK_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/tk"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── Helper: set up a minimal two-repo environment (main + worktree) ──────────
setup_two_repo_env() {
    local main_repo worktree_dir
    main_repo=$(mktemp -d)
    worktree_dir=$(mktemp -d)

    git -C "$main_repo" init -q -b main
    git -C "$main_repo" config user.email "test@test.com"
    git -C "$main_repo" config user.name "Test"

    mkdir -p "$main_repo/.tickets"
    echo "---
id: test-aaaa
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Test ticket from main" > "$main_repo/.tickets/test-aaaa.md"
    git -C "$main_repo" add .tickets/
    git -C "$main_repo" commit -q -m "init with tickets"

    git -C "$main_repo" worktree add -q "$worktree_dir" HEAD 2>/dev/null

    echo "${main_repo}:${worktree_dir}"
}

# --------------------------------------------------------------------------
# test_sync_dispatch_only_lists_read_commands
# The sync dispatch block must explicitly list read commands, not use a catch-all.
# Read commands: list, show, ready, blocked, search, count, children, closed
# --------------------------------------------------------------------------
SYNC_BLOCK=$(awk '/Auto-sync.*from main/,/esac/' "$TK_SCRIPT")

# Verify read commands are in the sync dispatch
for cmd in list show ready blocked search count children closed; do
    HAS_CMD=$(echo "$SYNC_BLOCK" | grep -cF "$cmd" || true)
    assert_ne "test_sync_dispatch_includes_$cmd" "0" "$HAS_CMD"
done

# --------------------------------------------------------------------------
# test_sync_dispatch_excludes_write_commands
# Write commands must NOT appear in the sync dispatch case arm that calls
# _sync_from_main. They should either be excluded or in the skip list.
# --------------------------------------------------------------------------
# Extract only the line(s) that call _sync_from_main in the sync dispatch block
SYNC_LINE=$(echo "$SYNC_BLOCK" | grep "_sync_from_main" || true)

# The sync dispatch should NOT have a catch-all (*) calling _sync_from_main
CATCHALL_SYNC=$(echo "$SYNC_BLOCK" | grep -c '^\s*\*)\s*_sync_from_main' || true)
assert_eq "test_sync_dispatch_no_catchall" "0" "$CATCHALL_SYNC"

# --------------------------------------------------------------------------
# test_write_commands_do_not_trigger_sync
# Verify write commands are not in the sync-triggering case arm.
# --------------------------------------------------------------------------
for cmd in create close reopen status start delete add-note assign priority parent tag; do
    # Check that the command is NOT in the case arm that calls _sync_from_main
    # (it should be in the skip list or simply not listed).
    # Use word-boundary grep to avoid "close" matching "closed".
    IN_SYNC_ARM=$(echo "$SYNC_BLOCK" | grep "_sync_from_main" | grep -cw "$cmd" || true)
    assert_eq "test_write_cmd_${cmd}_not_in_sync_arm" "0" "$IN_SYNC_ARM"
done

# --------------------------------------------------------------------------
# test_preserving_local_only_warning_exists
# _sync_from_main must contain the "preserving local-only" warning message.
# --------------------------------------------------------------------------
HAS_PRESERVE_MSG=$(grep -c 'preserving local-only' "$TK_SCRIPT" || true)
assert_ne "test_preserving_local_only_warning_exists" "0" "$HAS_PRESERVE_MSG"

# --------------------------------------------------------------------------
# test_sync_from_main_preserves_local_changes
# When a ticket file has local-only changes (simulating a failed push),
# _sync_from_main should NOT overwrite it.
# --------------------------------------------------------------------------
ENV_VARS=$(setup_two_repo_env)
MAIN_REPO="${ENV_VARS%%:*}"
WORKTREE_DIR="${ENV_VARS##*:}"

# First, do a normal sync so .last-sync-hash is populated
cd "$WORKTREE_DIR" && TICKETS_DIR="$WORKTREE_DIR/.tickets" bash "$TK_SCRIPT" list >/dev/null 2>&1 || true

# Record the current sync hash (this is the tree hash _sync_from_main synced from)
SYNCED_HASH=$(cat "$WORKTREE_DIR/.tickets/.last-sync-hash" 2>/dev/null)

# Now modify the ticket file locally in the worktree (simulating a local edit
# whose push hook failed)
echo "---
id: test-aaaa
status: closed
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Test ticket LOCALLY MODIFIED" > "$WORKTREE_DIR/.tickets/test-aaaa.md"

# Add a new commit on main so main:.tickets hash differs from the cached hash.
# This triggers _sync_from_main (hashes differ). We add a harmless new ticket
# so the only file at risk is test-aaaa.md which was locally modified.
echo "---
id: test-cccc
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Trigger ticket" > "$MAIN_REPO/.tickets/test-cccc.md"
git -C "$MAIN_REPO" add ".tickets/test-cccc.md"
git -C "$MAIN_REPO" commit -q -m "add trigger ticket"

# Run a read command — should preserve the local-only change
SYNC_OUTPUT=$(cd "$WORKTREE_DIR" && TICKETS_DIR="$WORKTREE_DIR/.tickets" bash "$TK_SCRIPT" list 2>&1 || true)

# The local content should be preserved (status: closed, not the main's status: open)
LOCAL_CONTENT=$(cat "$WORKTREE_DIR/.tickets/test-aaaa.md" 2>/dev/null || true)
assert_contains "test_sync_from_main_preserves_local_changes" "LOCALLY MODIFIED" "$LOCAL_CONTENT"

# The warning should have been emitted
assert_contains "test_sync_from_main_preserve_warning_emitted" "preserving local-only" "$SYNC_OUTPUT"

# Cleanup
git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
rm -rf "$MAIN_REPO" "$WORKTREE_DIR"

# --------------------------------------------------------------------------
# test_sync_from_main_does_sync_unchanged_files
# Files that are NOT locally modified should still be synced from main.
# --------------------------------------------------------------------------
ENV_VARS2=$(setup_two_repo_env)
MAIN_REPO2="${ENV_VARS2%%:*}"
WORKTREE_DIR2="${ENV_VARS2##*:}"

# Initial sync
cd "$WORKTREE_DIR2" && TICKETS_DIR="$WORKTREE_DIR2/.tickets" bash "$TK_SCRIPT" list >/dev/null 2>&1 || true

# Add a new ticket on main
mkdir -p "$MAIN_REPO2/.tickets"
echo "---
id: test-newb
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# New ticket from main" > "$MAIN_REPO2/.tickets/test-newb.md"
git -C "$MAIN_REPO2" add ".tickets/test-newb.md"
git -C "$MAIN_REPO2" commit -q -m "add test-newb"

# The worktree should pick up the new ticket
LIST_OUTPUT2=$(cd "$WORKTREE_DIR2" && TICKETS_DIR="$WORKTREE_DIR2/.tickets" bash "$TK_SCRIPT" list 2>/dev/null || true)
assert_contains "test_sync_from_main_syncs_unchanged_files" "test-newb" "$LIST_OUTPUT2"

# Cleanup
git -C "$MAIN_REPO2" worktree remove --force "$WORKTREE_DIR2" 2>/dev/null || true
rm -rf "$MAIN_REPO2" "$WORKTREE_DIR2"

# --------------------------------------------------------------------------
print_summary
