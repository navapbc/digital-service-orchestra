#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-sync-state-concurrent.sh
# Integration test: concurrent modification of .sync-state.json via _sync_ticket_file.
#
# Verifies that when two worktrees concurrently sync a .sync-state.json file
# using _sync_ticket_file, the resulting file on main is valid JSON and both
# worktrees can read the final state.
#
# Architecture: two independent clones (not linked worktrees) of the same bare
# repo, each writing a different version of .sync-state.json simultaneously
# using & and wait. This exercises the CAS retry path in tk-sync-lib.sh.
#
# Usage: bash lockpick-workflow/tests/hooks/test-sync-state-concurrent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SYNC_LIB="$REPO_ROOT/lockpick-workflow/scripts/tk-sync-lib.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── Helper: create a .sync-state.json with a unique entry ────────────────────
make_sync_state() {
    local dir="$1"
    local tk_id="$2"
    local jira_key="$3"
    mkdir -p "$dir/.tickets"
    cat > "$dir/.tickets/.sync-state.json" <<EOF
{
  "$tk_id": {
    "jira_key": "$jira_key",
    "local_hash": "abc123",
    "jira_hash": "",
    "last_synced": "2026-01-01T00:00:00Z"
  }
}
EOF
}

# ── Helper: create a minimal ticket file (needed for initial commit) ─────────
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
# Concurrent sync-state test ticket $ticket_id
EOF
}

# ── Helper: set up two-clone environment ─────────────────────────────────────
setup_two_clone_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo with initial commit containing .tickets/
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    make_ticket_file "$REALENV/seed" "seed-init"
    # Also create an initial .sync-state.json so the file exists on main
    cat > "$REALENV/seed/.tickets/.sync-state.json" <<EOF
{
  "seed-init": {
    "jira_key": "TEST-0",
    "local_hash": "seed",
    "jira_hash": "",
    "last_synced": "2026-01-01T00:00:00Z"
  }
}
EOF
    git -C "$REALENV/seed" add .tickets/
    git -C "$REALENV/seed" commit -q -m "init with tickets and sync-state"

    # 2. Bare repo from seed (acts as origin)
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
# Test 1: concurrent_sync_state_both_succeed
# Launch two _sync_ticket_file calls for .sync-state.json simultaneously.
# Both must exit 0 and .sync-state.json on main must be valid JSON.
# =============================================================================
TMPENV=$(setup_two_clone_env)
CLONE_A=$(cd "$TMPENV/clone-a" && pwd -P)
CLONE_B=$(cd "$TMPENV/clone-b" && pwd -P)
BARE="$TMPENV/bare.git"

# Write different .sync-state.json content in each clone
make_sync_state "$CLONE_A" "w21-aaaa" "TEST-100"
make_sync_state "$CLONE_B" "w21-bbbb" "TEST-200"

# Launch both _sync_ticket_file calls simultaneously in background subshells
(
    cd "$CLONE_A"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    export REPO_ROOT="$CLONE_A"
    source "$SYNC_LIB"
    _sync_ticket_file "$CLONE_A/.tickets/.sync-state.json"
) &
PID_A=$!

(
    cd "$CLONE_B"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    export REPO_ROOT="$CLONE_B"
    source "$SYNC_LIB"
    _sync_ticket_file "$CLONE_B/.tickets/.sync-state.json"
) &
PID_B=$!

wait $PID_A; EXIT_A=$?
wait $PID_B; EXIT_B=$?

# Both must exit 0 (fire-and-forget design)
assert_eq "concurrent_sync_state_a_exits_zero" "0" "$EXIT_A"
assert_eq "concurrent_sync_state_b_exits_zero" "0" "$EXIT_B"

# =============================================================================
# Test 2: .sync-state.json on main is valid JSON
# =============================================================================
SYNC_STATE_CONTENT=$(git -C "$BARE" show main:.tickets/.sync-state.json 2>/dev/null) || SYNC_STATE_CONTENT=""

# Must not be empty
assert_ne "sync_state_not_empty" "" "$SYNC_STATE_CONTENT"

# Must be valid JSON (python3 json.loads will fail on corrupt/partial content)
JSON_VALID=$(echo "$SYNC_STATE_CONTENT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    # Must be a dict (the sync-state format)
    if isinstance(data, dict):
        print('valid')
    else:
        print('invalid_type')
except Exception as e:
    print('invalid_json: ' + str(e))
" 2>&1)

assert_eq "sync_state_is_valid_json" "valid" "$JSON_VALID"

# =============================================================================
# Test 3: both worktrees can read the final state from main
# =============================================================================

# Pull the final state into clone-a
CLONE_A_READ=$(git -C "$CLONE_A" fetch origin main 2>/dev/null && \
    git -C "$CLONE_A" show origin/main:.tickets/.sync-state.json 2>/dev/null) || CLONE_A_READ=""
CLONE_A_VALID=$(echo "$CLONE_A_READ" | python3 -c "
import json, sys
try:
    json.load(sys.stdin)
    print('valid')
except:
    print('invalid')
" 2>&1)

assert_eq "clone_a_can_read_final_state" "valid" "$CLONE_A_VALID"

# Pull the final state into clone-b
CLONE_B_READ=$(git -C "$CLONE_B" fetch origin main 2>/dev/null && \
    git -C "$CLONE_B" show origin/main:.tickets/.sync-state.json 2>/dev/null) || CLONE_B_READ=""
CLONE_B_VALID=$(echo "$CLONE_B_READ" | python3 -c "
import json, sys
try:
    json.load(sys.stdin)
    print('valid')
except:
    print('invalid')
" 2>&1)

assert_eq "clone_b_can_read_final_state" "valid" "$CLONE_B_VALID"

# =============================================================================
# Test 4: seed entry still present (no tree corruption)
# =============================================================================
HAS_SEED=$(git -C "$BARE" show main:.tickets/seed-init.md 2>/dev/null | grep -c "seed-init" || true)
assert_ne "concurrent_sync_state_preserves_seed_ticket" "0" "$HAS_SEED"

# Cleanup
rm -rf "$TMPENV"

# =============================================================================
print_summary
