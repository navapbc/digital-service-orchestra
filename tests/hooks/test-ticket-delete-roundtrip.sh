#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-ticket-delete-roundtrip.sh
# Integration test for _sync_ticket_delete round-trip across worktrees.
#
# Verifies:
#   1. Create a ticket in worktree A and push it via _sync_ticket_file
#   2. Delete the ticket file in worktree A
#   3. Call _sync_ticket_delete to push the deletion to main
#   4. Verify the ticket no longer exists on main (in the bare repo)
#   5. Verify worktree B sees the deletion after sync
#
# Usage: bash lockpick-workflow/tests/hooks/test-ticket-delete-roundtrip.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TK_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/tk"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/scripts/tk-sync-lib.sh"

# ── Helper: create a minimal ticket file ─────────────────────────────────────
make_ticket_file() {
    local dir="$1"
    local ticket_id="$2"
    mkdir -p "$dir/.tickets"
    cat > "$dir/.tickets/${ticket_id}.md" <<EOF
---
id: $ticket_id
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Test ticket $ticket_id
EOF
}

# ── Helper: set up two-worktree environment ───────────────────────────────────
# Creates:
#   $REALENV/bare.git       — bare repo acting as "origin"
#   $REALENV/main-a/        — main repo for worktree A (cloned from bare)
#   $REALENV/worktree-a/    — worktree A (linked from main-a)
#   $REALENV/worktree-b/    — worktree B (linked from main-a)
#
# All paths are canonicalized with pwd -P to avoid /var vs /private/var issues on macOS.
setup_two_worktree_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo: create initial commit with .tickets/
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    make_ticket_file "$REALENV/seed" "seed-init"
    git -C "$REALENV/seed" add .tickets/
    git -C "$REALENV/seed" commit -q -m "init with tickets"

    # 2. Bare repo cloned from seed (acts as origin)
    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"

    # 3. Clone bare into main-a (full clone with remote=origin pointing to bare)
    git clone -q "$REALENV/bare.git" "$REALENV/main-a"
    git -C "$REALENV/main-a" config user.email "test@test.com"
    git -C "$REALENV/main-a" config user.name "Test"

    # 4. Create two worktrees from main-a
    git -C "$REALENV/main-a" worktree add -q "$REALENV/worktree-a" HEAD 2>/dev/null
    git -C "$REALENV/main-a" worktree add -q "$REALENV/worktree-b" HEAD 2>/dev/null

    echo "$REALENV"
}

# =============================================================================
# Test 1: delete_roundtrip_removes_from_main
# Create a ticket in worktree A, push it, delete it, push the deletion,
# then verify it no longer exists on main in the bare repo.
# =============================================================================
TMPENV1=$(setup_two_worktree_env)
WT_A1=$(cd "$TMPENV1/worktree-a" && pwd -P)
WT_B1=$(cd "$TMPENV1/worktree-b" && pwd -P)
MAIN_A1="$TMPENV1/main-a"
BARE1="$TMPENV1/bare.git"

# Step 1: Create a ticket in worktree A and push via _sync_ticket_file
make_ticket_file "$WT_A1" "del-roundtrip"
(
    cd "$WT_A1"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    REPO_ROOT="$WT_A1" _sync_ticket_file "$WT_A1/.tickets/del-roundtrip.md"
)

# Verify ticket exists on main before deletion
FILE_EXISTS_BEFORE=$(git -C "$BARE1" show main:.tickets/del-roundtrip.md 2>/dev/null | grep -c "del-roundtrip" || true)
assert_ne "test_ticket_exists_on_main_before_delete" "0" "$FILE_EXISTS_BEFORE"

# Step 2: Delete the ticket file on disk
rm -f "$WT_A1/.tickets/del-roundtrip.md"

# Step 3: Push the deletion via _sync_ticket_delete
(
    cd "$WT_A1"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    REPO_ROOT="$WT_A1" _sync_ticket_delete "$WT_A1/.tickets/del-roundtrip.md"
)

# Step 4: Verify ticket no longer exists on main (bare repo)
FILE_EXISTS_AFTER=$(git -C "$BARE1" show main:.tickets/del-roundtrip.md 2>&1 || true)
# git show should fail or return empty — check it does NOT contain ticket content
if echo "$FILE_EXISTS_AFTER" | grep -q "del-roundtrip"; then
    # It might match the error message containing the path; check if it's actual content
    HAS_FRONTMATTER=$(echo "$FILE_EXISTS_AFTER" | grep -c "^status:" || true)
else
    HAS_FRONTMATTER=0
fi
assert_eq "test_ticket_removed_from_main_after_delete" "0" "$HAS_FRONTMATTER"

# Step 5: Verify worktree B sees the deletion after sync
# Fetch updates into main-a from bare origin
git -C "$MAIN_A1" fetch -q origin 2>/dev/null || true
git -C "$MAIN_A1" reset -q --hard origin/main 2>/dev/null || true

# Invalidate worktree B's sync hash so _sync_from_main will re-checkout
rm -f "$WT_B1/.tickets/.last-sync-hash"

# Run tk list in worktree B — the deleted ticket should NOT appear
LIST_B1=$(
    cd "$WT_B1"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    TICKETS_DIR="$WT_B1/.tickets" bash "$TK_SCRIPT" list 2>/dev/null || true
)

# del-roundtrip should not be in the list
if echo "$LIST_B1" | grep -q "del-roundtrip"; then
    DELETED_VISIBLE="true"
else
    DELETED_VISIBLE="false"
fi
assert_eq "test_deleted_ticket_not_visible_in_worktree_b" "false" "$DELETED_VISIBLE"

# Verify the seed ticket still exists (deletion didn't corrupt the tree)
SEED_EXISTS=$(git -C "$BARE1" show main:.tickets/seed-init.md 2>/dev/null | grep -c "seed-init" || true)
assert_ne "test_seed_ticket_still_exists_after_delete" "0" "$SEED_EXISTS"

# Cleanup
rm -rf "$TMPENV1"

# =============================================================================
# Test 2: delete_of_nonexistent_file_is_noop
# Calling _sync_ticket_delete for a file that was never on main should not
# error and should not corrupt the tree.
# =============================================================================
TMPENV2=$(setup_two_worktree_env)
WT_A2=$(cd "$TMPENV2/worktree-a" && pwd -P)
BARE2="$TMPENV2/bare.git"

# Count tree entries before
TREE_BEFORE2=$(git -C "$BARE2" ls-tree -r main | wc -l | tr -d ' ')

# Try to delete a ticket that was never created/pushed
DELETE_EXIT2=0
(
    cd "$WT_A2"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    REPO_ROOT="$WT_A2" _sync_ticket_delete "$WT_A2/.tickets/never-existed.md"
) || DELETE_EXIT2=$?

assert_eq "test_delete_nonexistent_exits_zero" "0" "$DELETE_EXIT2"

# Tree should be unchanged (or have one more commit but same tree content)
TREE_AFTER2=$(git -C "$BARE2" ls-tree -r main | wc -l | tr -d ' ')
assert_eq "test_delete_nonexistent_preserves_tree" "$TREE_BEFORE2" "$TREE_AFTER2"

# Seed ticket should still exist
SEED_EXISTS2=$(git -C "$BARE2" show main:.tickets/seed-init.md 2>/dev/null | grep -c "seed-init" || true)
assert_ne "test_seed_survives_nonexistent_delete" "0" "$SEED_EXISTS2"

# Cleanup
rm -rf "$TMPENV2"

# =============================================================================
print_summary
