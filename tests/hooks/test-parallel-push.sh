#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-parallel-push.sh
# Integration test: true-parallel concurrent pushes using background subshells.
#
# Verifies that when two independent clones run _sync_ticket_file simultaneously
# (via & and wait), both pushes succeed and both ticket files are present on main
# in the bare origin. This exercises the CAS (compare-and-swap) retry path in
# tk-sync-lib.sh when git push returns non-fast-forward.
#
# Architecture: two independent clones (not linked worktrees) of the same bare
# repo, so the local update-ref never races — only the push to origin does.
# This matches the real-world scenario of two worktrees from different checkouts.
#
# Usage: bash lockpick-workflow/tests/hooks/test-parallel-push.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SYNC_LIB="$REPO_ROOT/lockpick-workflow/scripts/tk-sync-lib.sh"

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
# Parallel push test ticket $ticket_id
EOF
}

# ── Helper: set up two-clone environment ──────────────────────────────────────
# Creates:
#   $REALENV/bare.git   — bare repo acting as "origin"
#   $REALENV/clone-a/   — independent clone A
#   $REALENV/clone-b/   — independent clone B
#
# Both clones share the same origin but have separate .git dirs, so local
# update-ref operations never race — only pushes to origin do.
setup_two_clone_env() {
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

    # 3. Two independent clones from bare
    git clone -q "$REALENV/bare.git" "$REALENV/clone-a"
    git -C "$REALENV/clone-a" config user.email "test@test.com"
    git -C "$REALENV/clone-a" config user.name "Test"

    git clone -q "$REALENV/bare.git" "$REALENV/clone-b"
    git -C "$REALENV/clone-b" config user.email "test@test.com"
    git -C "$REALENV/clone-b" config user.name "Test"

    echo "$REALENV"
}

# =============================================================================
# Test 1: true_parallel_push_both_succeed
# Launch two _sync_ticket_file calls simultaneously using & and wait.
# Both must exit 0 and both ticket files must be present on main in the bare repo.
# =============================================================================
TMPENV=$(setup_two_clone_env)
CLONE_A=$(cd "$TMPENV/clone-a" && pwd -P)
CLONE_B=$(cd "$TMPENV/clone-b" && pwd -P)
BARE="$TMPENV/bare.git"

# Create distinct ticket files in each clone
make_ticket_file "$CLONE_A" "parallel-a"
make_ticket_file "$CLONE_B" "parallel-b"

# Launch both _sync_ticket_file calls simultaneously in background subshells.
# Each subshell:
#   - cd into its clone
#   - unset git env vars to avoid cross-contamination
#   - set REPO_ROOT to its clone path
#   - source the sync library and invoke the function
(
    cd "$CLONE_A"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    export REPO_ROOT="$CLONE_A"
    source "$SYNC_LIB"
    _sync_ticket_file "$CLONE_A/.tickets/parallel-a.md"
) &
PID_A=$!

(
    cd "$CLONE_B"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    export REPO_ROOT="$CLONE_B"
    source "$SYNC_LIB"
    _sync_ticket_file "$CLONE_B/.tickets/parallel-b.md"
) &
PID_B=$!

wait $PID_A; EXIT_A=$?
wait $PID_B; EXIT_B=$?

# Both must exit 0 (fire-and-forget design)
assert_eq "test_parallel_push_a_exits_zero" "0" "$EXIT_A"
assert_eq "test_parallel_push_b_exits_zero" "0" "$EXIT_B"

# Both ticket files must exist on main in the bare repo.
# One push raced and was rebased onto the other via the retry path.
FILE_A=$(git -C "$BARE" show main:.tickets/parallel-a.md 2>/dev/null | grep -c "parallel-a" || true)
FILE_B=$(git -C "$BARE" show main:.tickets/parallel-b.md 2>/dev/null | grep -c "parallel-b" || true)

assert_ne "test_parallel_push_file_a_present_on_main" "0" "$FILE_A"
assert_ne "test_parallel_push_file_b_present_on_main" "0" "$FILE_B"

# Verify the seed ticket still exists (no tree corruption from parallel pushes)
HAS_SEED=$(git -C "$BARE" show main:.tickets/seed-init.md 2>/dev/null | grep -c "seed-init" || true)
assert_ne "test_parallel_push_preserves_seed_ticket" "0" "$HAS_SEED"

# Cleanup
rm -rf "$TMPENV"

# =============================================================================
print_summary
