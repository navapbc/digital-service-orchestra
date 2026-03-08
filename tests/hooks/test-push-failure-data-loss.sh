#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-push-failure-data-loss.sh
# Integration test: push failure followed by _sync_from_main must NOT
# overwrite local-only ticket changes.
#
# Scenario:
#   1. Create a two-worktree environment
#   2. Create/modify a ticket in worktree A and push it via the hook
#   3. Modify the ticket AGAIN locally (simulating content that hasn't been pushed)
#   4. Invalidate .last-sync-hash to force _sync_from_main to run
#   5. Run `tk list` (triggers _sync_from_main)
#   6. Verify the local ticket content is preserved (not overwritten by main)
#
# Usage: bash lockpick-workflow/tests/hooks/test-push-failure-data-loss.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TK_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/tk"
PUSH_HOOK="$REPO_ROOT/lockpick-workflow/hooks/ticket-sync-push.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

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
# Integration test ticket $ticket_id
EOF
}

# ── Helper: set up two-worktree environment ───────────────────────────────────
setup_two_worktree_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    make_ticket_file "$REALENV/seed" "seed-init"
    git -C "$REALENV/seed" add .tickets/
    git -C "$REALENV/seed" commit -q -m "init with tickets"

    # 2. Bare repo (acts as origin)
    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"

    # 3. Clone into main-a
    git clone -q "$REALENV/bare.git" "$REALENV/main-a"
    git -C "$REALENV/main-a" config user.email "test@test.com"
    git -C "$REALENV/main-a" config user.name "Test"

    # 4. Create worktrees
    git -C "$REALENV/main-a" worktree add -q "$REALENV/worktree-a" HEAD 2>/dev/null
    git -C "$REALENV/main-a" worktree add -q "$REALENV/worktree-b" HEAD 2>/dev/null

    echo "$REALENV"
}

# ── Helper: invoke the push hook for a file ───────────────────────────────────
invoke_push_hook_for_file() {
    local worktree_dir="$1"
    local ticket_path="$2"
    local input
    input=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"tool_response":{"success":true}}' "$ticket_path")
    (
        cd "$worktree_dir"
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        echo "$input" | bash "$PUSH_HOOK" >/dev/null 2>/dev/null
    )
}

# ── Helper: run tk list in a worktree ─────────────────────────────────────────
read_tickets_in_worktree() {
    local worktree_dir="$1"
    (
        cd "$worktree_dir"
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
        TICKETS_DIR="$worktree_dir/.tickets" bash "$TK_SCRIPT" list 2>/dev/null || true
    )
}

# =============================================================================
# Test 1: local_change_preserved_after_failed_push
# Modify a ticket locally after a successful push (simulating a push failure
# for the second edit), then trigger _sync_from_main and verify the local
# content survives.
# =============================================================================
TMPENV1=$(setup_two_worktree_env)
WT_A1=$(cd "$TMPENV1/worktree-a" && pwd -P)
MAIN_A1="$TMPENV1/main-a"

# Step 1: Create a ticket in worktree A and push it (this succeeds)
make_ticket_file "$WT_A1" "push-fail-test"
invoke_push_hook_for_file "$WT_A1" "$WT_A1/.tickets/push-fail-test.md"

# Step 2: Fetch the pushed content into main-a so main ref is up-to-date
git -C "$MAIN_A1" fetch -q origin 2>/dev/null || true
git -C "$MAIN_A1" reset -q --hard origin/main 2>/dev/null || true

# Step 3: Modify the ticket locally (simulating an edit whose push failed)
# The local version now differs from what's on main.
UNIQUE_MARKER="LOCAL-ONLY-CONTENT-$(date +%s)"
cat > "$WT_A1/.tickets/push-fail-test.md" <<EOF
---
id: push-fail-test
status: in_progress
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 1
---
# $UNIQUE_MARKER
This content was modified locally but the push failed.
EOF

# Step 4: Invalidate .last-sync-hash to force _sync_from_main to run
rm -f "$WT_A1/.tickets/.last-sync-hash"

# Step 5: Run tk list (triggers _sync_from_main)
_LIST_OUTPUT=$(read_tickets_in_worktree "$WT_A1")

# Step 6: Verify the local content is preserved
ACTUAL_CONTENT=$(cat "$WT_A1/.tickets/push-fail-test.md" 2>/dev/null || true)
assert_contains "test_local_change_preserved_after_sync" "$UNIQUE_MARKER" "$ACTUAL_CONTENT"

# Also verify the status change (in_progress) was preserved, not reverted to open
assert_contains "test_local_status_preserved" "status: in_progress" "$ACTUAL_CONTENT"

# Also verify priority change was preserved
assert_contains "test_local_priority_preserved" "priority: 1" "$ACTUAL_CONTENT"

rm -rf "$TMPENV1"

# =============================================================================
# Test 2: push_failure_via_broken_remote
# Break the remote URL so the push hook actually fails, then verify that a
# subsequent tk list does not overwrite the local change.
# =============================================================================
TMPENV2=$(setup_two_worktree_env)
WT_A2=$(cd "$TMPENV2/worktree-a" && pwd -P)
MAIN_A2="$TMPENV2/main-a"

# Step 1: Create an initial ticket and push it successfully
make_ticket_file "$WT_A2" "broken-remote-test"
invoke_push_hook_for_file "$WT_A2" "$WT_A2/.tickets/broken-remote-test.md"

# Step 2: Fetch so main-a sees the pushed content
git -C "$MAIN_A2" fetch -q origin 2>/dev/null || true
git -C "$MAIN_A2" reset -q --hard origin/main 2>/dev/null || true

# Step 3: Break the remote URL so future pushes fail
git -C "$MAIN_A2" remote set-url origin "/nonexistent/path/to/repo.git"

# Step 4: Modify the ticket locally
UNIQUE_MARKER2="BROKEN-REMOTE-EDIT-$(date +%s)"
cat > "$WT_A2/.tickets/broken-remote-test.md" <<EOF
---
id: broken-remote-test
status: closed
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 0
---
# $UNIQUE_MARKER2
This edit was made while the remote was broken.
EOF

# Step 5: Try to push (should fail silently — hook is fire-and-forget)
PUSH_EXIT=0
invoke_push_hook_for_file "$WT_A2" "$WT_A2/.tickets/broken-remote-test.md" || PUSH_EXIT=$?

# The push hook should still exit 0 (fire-and-forget)
assert_eq "test_push_hook_exits_zero_on_broken_remote" "0" "$PUSH_EXIT"

# Step 6: Fix the remote URL so _sync_from_main can resolve refs
# (In reality, the remote may come back later. Here we restore it so
# _sync_from_main can run its git rev-parse against the local main ref.)
git -C "$MAIN_A2" remote set-url origin "$TMPENV2/bare.git"

# Step 7: Invalidate .last-sync-hash to force sync
rm -f "$WT_A2/.tickets/.last-sync-hash"

# Step 8: Run tk list (triggers _sync_from_main)
_LIST_OUTPUT2=$(read_tickets_in_worktree "$WT_A2")

# Step 9: Verify local content is preserved
ACTUAL_CONTENT2=$(cat "$WT_A2/.tickets/broken-remote-test.md" 2>/dev/null || true)
assert_contains "test_broken_remote_local_content_preserved" "$UNIQUE_MARKER2" "$ACTUAL_CONTENT2"
assert_contains "test_broken_remote_status_preserved" "status: closed" "$ACTUAL_CONTENT2"

rm -rf "$TMPENV2"

# =============================================================================
# Test 3: new_local_ticket_not_deleted_by_sync
# Create a brand-new ticket locally (never pushed), then trigger
# _sync_from_main and verify the new ticket file still exists.
# =============================================================================
TMPENV3=$(setup_two_worktree_env)
WT_A3=$(cd "$TMPENV3/worktree-a" && pwd -P)
MAIN_A3="$TMPENV3/main-a"

# Step 1: Create a ticket that exists ONLY locally (never pushed)
UNIQUE_MARKER3="NEVER-PUSHED-$(date +%s)"
mkdir -p "$WT_A3/.tickets"
cat > "$WT_A3/.tickets/local-only-ticket.md" <<EOF
---
id: local-only-ticket
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 3
---
# $UNIQUE_MARKER3
This ticket was never pushed to main.
EOF

# Step 2: Invalidate .last-sync-hash to force sync
rm -f "$WT_A3/.tickets/.last-sync-hash"

# Step 3: Run tk list
_LIST_OUTPUT3=$(read_tickets_in_worktree "$WT_A3")

# Step 4: Verify the local-only ticket file still exists
assert_eq "test_new_local_ticket_file_exists" "true" \
    "$([ -f "$WT_A3/.tickets/local-only-ticket.md" ] && echo true || echo false)"

# Verify content is intact
ACTUAL_CONTENT3=$(cat "$WT_A3/.tickets/local-only-ticket.md" 2>/dev/null || true)
assert_contains "test_new_local_ticket_content_intact" "$UNIQUE_MARKER3" "$ACTUAL_CONTENT3"

rm -rf "$TMPENV3"

# =============================================================================
print_summary
