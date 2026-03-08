#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-ticket-sync-pull.sh
# Tests for _sync_from_main() in scripts/tk.
#
# The function auto-pulls .tickets/ from main when a read subcommand runs,
# using a cached hash to avoid redundant checkouts.
#
# Usage: bash lockpick-workflow/tests/hooks/test-ticket-sync-pull.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TK_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/tk"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── Helper: set up a minimal two-repo environment (main + worktree) ──────────
# Returns the worktree path via stdout; caller must rm -rf the two temp dirs.
setup_two_repo_env() {
    local main_repo worktree_dir
    main_repo=$(mktemp -d)
    worktree_dir=$(mktemp -d)

    # Initialise main repo
    git -C "$main_repo" init -q -b main
    git -C "$main_repo" config user.email "test@test.com"
    git -C "$main_repo" config user.name "Test"

    # Create an initial commit with a .tickets/ directory
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

    # Create a worktree from main
    git -C "$main_repo" worktree add -q "$worktree_dir" HEAD 2>/dev/null

    # Return both paths separated by ':'
    echo "${main_repo}:${worktree_dir}"
}

# ── Helper: add a new ticket to main and commit it ───────────────────────────
add_ticket_to_main() {
    local main_repo="$1"
    local ticket_id="${2:-test-bbbb}"
    mkdir -p "$main_repo/.tickets"
    echo "---
id: $ticket_id
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# New ticket $ticket_id" > "$main_repo/.tickets/${ticket_id}.md"
    git -C "$main_repo" add ".tickets/${ticket_id}.md"
    git -C "$main_repo" commit -q -m "add $ticket_id"
}

# --------------------------------------------------------------------------
# test_sync_from_main_function_exists
# The _sync_from_main function must be defined in scripts/tk
FUNC_EXISTS=$(grep -c "_sync_from_main" "$TK_SCRIPT" || true)
assert_ne "test_sync_from_main_function_exists" "0" "$FUNC_EXISTS"

# --------------------------------------------------------------------------
# test_sync_from_main_called_for_list
# The read command dispatch block must call _sync_from_main, and must include
# list, show, and ready in the same block.
# Strategy: find the case arm that includes list|show|ready and verify it calls
# _sync_from_main within a few lines.
DISPATCH_LIST=$(awk '/list.*show.*ready|ready.*list.*show/{found=1} found && /_sync_from_main/{print; exit}' "$TK_SCRIPT" | wc -l | tr -d ' ')
assert_ne "test_sync_from_main_called_for_read_commands" "0" "$DISPATCH_LIST"

# --------------------------------------------------------------------------
# test_gitignore_has_last_sync_hash
# .tickets/.last-sync-hash must be in .gitignore
GITIGNORE_HAS_HASH=$(grep -c ".tickets/.last-sync-hash" "$REPO_ROOT/.gitignore" || true)
assert_ne "test_gitignore_has_last_sync_hash" "0" "$GITIGNORE_HAS_HASH"

# --------------------------------------------------------------------------
# test_sync_from_main_pulls_new_ticket_on_list
# When main has a ticket not in the worktree, tk list should pull it.
ENV_VARS=$(setup_two_repo_env)
MAIN_REPO="${ENV_VARS%%:*}"
WORKTREE_DIR="${ENV_VARS##*:}"

# Add a new ticket to main that doesn't exist in the worktree
add_ticket_to_main "$MAIN_REPO" "test-newx"

# Run tk list in the worktree — should auto-pull and show the new ticket
LIST_OUTPUT=$(cd "$WORKTREE_DIR" && TICKETS_DIR="$WORKTREE_DIR/.tickets" bash "$TK_SCRIPT" list 2>/dev/null || true)
assert_contains "test_sync_from_main_pulls_new_ticket_on_list" "test-newx" "$LIST_OUTPUT"

# Cleanup
git -C "$MAIN_REPO" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
rm -rf "$MAIN_REPO" "$WORKTREE_DIR"

# --------------------------------------------------------------------------
# test_sync_from_main_hash_file_written
# After sync, .last-sync-hash must exist under .tickets/ in the worktree.
ENV_VARS2=$(setup_two_repo_env)
MAIN_REPO2="${ENV_VARS2%%:*}"
WORKTREE_DIR2="${ENV_VARS2##*:}"

# Run a read command in the worktree
cd "$WORKTREE_DIR2" && TICKETS_DIR="$WORKTREE_DIR2/.tickets" bash "$TK_SCRIPT" list >/dev/null 2>&1 || true

HASH_FILE_EXISTS=0
[[ -f "$WORKTREE_DIR2/.tickets/.last-sync-hash" ]] && HASH_FILE_EXISTS=1
assert_eq "test_sync_from_main_hash_file_written" "1" "$HASH_FILE_EXISTS"

# Cleanup
git -C "$MAIN_REPO2" worktree remove --force "$WORKTREE_DIR2" 2>/dev/null || true
rm -rf "$MAIN_REPO2" "$WORKTREE_DIR2"

# --------------------------------------------------------------------------
# test_sync_from_main_no_sync_when_hash_matches
# When .last-sync-hash already matches main:.tickets hash, no git checkout runs.
ENV_VARS3=$(setup_two_repo_env)
MAIN_REPO3="${ENV_VARS3%%:*}"
WORKTREE_DIR3="${ENV_VARS3##*:}"

# Pre-populate .tickets/.last-sync-hash with the current main:.tickets hash
CURRENT_HASH=$(git -C "$WORKTREE_DIR3" rev-parse main:.tickets 2>/dev/null || true)
echo "$CURRENT_HASH" > "$WORKTREE_DIR3/.tickets/.last-sync-hash"

# Ensure ticket file exists in the worktree (already there from initial commit)
# Count tickets before list — should stay the same (no new checkout needed)
BEFORE_COUNT=$(ls "$WORKTREE_DIR3/.tickets/"*.md 2>/dev/null | wc -l | tr -d ' ')

cd "$WORKTREE_DIR3" && TICKETS_DIR="$WORKTREE_DIR3/.tickets" bash "$TK_SCRIPT" list >/dev/null 2>&1 || true

AFTER_COUNT=$(ls "$WORKTREE_DIR3/.tickets/"*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "test_sync_from_main_no_sync_when_hash_matches" "$BEFORE_COUNT" "$AFTER_COUNT"

# Cleanup
git -C "$MAIN_REPO3" worktree remove --force "$WORKTREE_DIR3" 2>/dev/null || true
rm -rf "$MAIN_REPO3" "$WORKTREE_DIR3"

# --------------------------------------------------------------------------
# test_sync_from_main_skips_outside_worktree
# When not in a git worktree (fresh repo or main), _sync_from_main must not crash.
TMPDIR_FRESH=$(mktemp -d)
mkdir -p "$TMPDIR_FRESH/.tickets"
echo "---
id: fresh-aaaa
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Fresh ticket" > "$TMPDIR_FRESH/.tickets/fresh-aaaa.md"

# Run list in a non-git-worktree dir — should not crash and should show tickets
FRESH_OUTPUT=$(cd "$TMPDIR_FRESH" && TICKETS_DIR="$TMPDIR_FRESH/.tickets" bash "$TK_SCRIPT" list 2>/dev/null || true)
assert_contains "test_sync_from_main_skips_outside_worktree" "fresh-aaaa" "$FRESH_OUTPUT"

rm -rf "$TMPDIR_FRESH"

# --------------------------------------------------------------------------
# test_sync_from_main_write_commands_do_not_trigger_sync
# Write subcommands (create) must NOT call _sync_from_main.
# Verify by checking the dispatch structure: write commands lack the _sync_from_main call.
# We inspect the actual dispatch block in tk for write-only commands.
CREATE_HAS_SYNC=$(awk '/case.*\$\{1:-help\}/,/esac/' "$TK_SCRIPT" | \
    grep -A1 "create)" | grep -c "_sync_from_main" || true)
assert_eq "test_sync_from_main_write_commands_do_not_trigger_sync" "0" "$CREATE_HAS_SYNC"

# --------------------------------------------------------------------------
# test_sync_from_main_handles_missing_main_ref_gracefully
# When main:.tickets doesn't exist (fresh repo), function exits 0 silently.
TMPDIR_NOMAIN=$(mktemp -d)
git -C "$TMPDIR_NOMAIN" init -q -b main
git -C "$TMPDIR_NOMAIN" config user.email "test@test.com"
git -C "$TMPDIR_NOMAIN" config user.name "Test"
git -C "$TMPDIR_NOMAIN" commit --allow-empty -q -m "init"
mkdir -p "$TMPDIR_NOMAIN/.tickets"
echo "---
id: nomain-aaaa
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# No-main ticket" > "$TMPDIR_NOMAIN/.tickets/nomain-aaaa.md"

# Should not error even though there's no main:.tickets tree
NOMAIN_EXIT=0
(cd "$TMPDIR_NOMAIN" && TICKETS_DIR="$TMPDIR_NOMAIN/.tickets" bash "$TK_SCRIPT" list >/dev/null 2>&1) || NOMAIN_EXIT=$?
assert_eq "test_sync_from_main_handles_missing_main_ref_gracefully" "0" "$NOMAIN_EXIT"

rm -rf "$TMPDIR_NOMAIN"

# --------------------------------------------------------------------------
print_summary
