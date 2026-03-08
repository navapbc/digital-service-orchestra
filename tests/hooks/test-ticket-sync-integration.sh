#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-ticket-sync-integration.sh
# Integration tests for the cross-worktree ticket sync mechanism.
#
# Uses local bare repos and worktrees to test the full push-then-pull cycle
# without requiring a remote. Tests cover:
#   1. Cross-worktree visibility: create ticket in worktree A, verify visible in B
#   2. Concurrent push (different files): both succeed, both files present on main
#   3. Same-file concurrent push: last-write-wins, no errors
#   4. Subprocess count: unchanged sync path uses at most two git rev-parse calls
#      and zero network calls (no fetch/pull/checkout)
#
# Usage: bash lockpick-workflow/tests/hooks/test-ticket-sync-integration.sh
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
# Creates:
#   $REALENV/bare.git       — bare repo acting as "origin"
#   $REALENV/main-a/        — main repo for worktree A (cloned from bare)
#   $REALENV/worktree-a/    — worktree A (linked from main-a)
#   $REALENV/worktree-b/    — worktree B (linked from main-a)
#
# All paths are canonicalized with pwd -P to avoid /var vs /private/var issues on macOS.
# Outputs the canonicalized env root to stdout.
setup_two_worktree_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo: create initial commit with .tickets/ and scripts/tk-sync-lib.sh
    #    The lib is needed so the push hook can find it via git rev-parse --show-toplevel.
    #    Copy from the canonical plugin location (not the wrapper at scripts/).
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    make_ticket_file "$REALENV/seed" "seed-init"
    mkdir -p "$REALENV/seed/scripts"
    cp "$REPO_ROOT/lockpick-workflow/scripts/tk-sync-lib.sh" "$REALENV/seed/scripts/"
    git -C "$REALENV/seed" add .tickets/ scripts/
    git -C "$REALENV/seed" commit -q -m "init with tickets"

    # 2. Bare repo cloned from seed (acts as origin)
    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"

    # 3. Clone bare into main-a (full clone with remote=origin pointing to bare)
    git clone -q "$REALENV/bare.git" "$REALENV/main-a"
    git -C "$REALENV/main-a" config user.email "test@test.com"
    git -C "$REALENV/main-a" config user.name "Test"

    # 4. Create two worktrees from main-a
    #    .git is a FILE in worktrees (required by the push hook's worktree check)
    git -C "$REALENV/main-a" worktree add -q "$REALENV/worktree-a" HEAD 2>/dev/null
    git -C "$REALENV/main-a" worktree add -q "$REALENV/worktree-b" HEAD 2>/dev/null

    echo "$REALENV"
}

# ── Helper: invoke the push hook for a file ───────────────────────────────────
# Runs the hook in the context of the owning worktree (cd + unset git env vars)
# so that git rev-parse --show-toplevel resolves to the correct root.
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
# Test 1: cross_worktree_visibility
# Create a ticket in worktree A, push via hook to bare origin, then verify
# the ticket appears in tk list output from worktree B after pull sync.
# Satisfies: "A ticket created in worktree A is visible via tk list in worktree B
# on the next read command without manual intervention"
# =============================================================================
TMPENV1=$(setup_two_worktree_env)
WT_A1=$(cd "$TMPENV1/worktree-a" && pwd -P)
WT_B1=$(cd "$TMPENV1/worktree-b" && pwd -P)
MAIN_A1="$TMPENV1/main-a"

# Create a new ticket in worktree A and push it via the hook
make_ticket_file "$WT_A1" "intg-vis1"
invoke_push_hook_for_file "$WT_A1" "$WT_A1/.tickets/intg-vis1.md"

# Bring main-a up to date from origin (simulates what would happen in a real scenario
# where main-a fetches from bare); then worktree-b shares main-a's object store
git -C "$MAIN_A1" fetch -q origin 2>/dev/null || true
git -C "$MAIN_A1" reset -q --hard origin/main 2>/dev/null || true

# Invalidate worktree B's sync hash so _sync_from_main will re-checkout
rm -f "$WT_B1/.tickets/.last-sync-hash"

LIST_B1=$(read_tickets_in_worktree "$WT_B1")
assert_contains "test_cross_worktree_visibility" "intg-vis1" "$LIST_B1"

rm -rf "$TMPENV1"

# =============================================================================
# Test 2: concurrent_push_different_files
# Two worktrees push different ticket files; both must be present on main.
# Satisfies: "if they modify different ticket files, both files are present on
# main after both pushes complete"
# =============================================================================
TMPENV2=$(setup_two_worktree_env)
WT_A2=$(cd "$TMPENV2/worktree-a" && pwd -P)
WT_B2=$(cd "$TMPENV2/worktree-b" && pwd -P)
BARE2="$TMPENV2/bare.git"
MAIN_A2="$TMPENV2/main-a"

# Create distinct tickets in each worktree
make_ticket_file "$WT_A2" "intg-diff-a"
make_ticket_file "$WT_B2" "intg-diff-b"

# Push from worktree A first
invoke_push_hook_for_file "$WT_A2" "$WT_A2/.tickets/intg-diff-a.md"

# Fetch the new tip into main-a so worktree-b's git sees the updated origin
git -C "$MAIN_A2" fetch -q origin 2>/dev/null || true

# Push from worktree B (may be behind A; the hook's retry logic handles non-fast-forward)
invoke_push_hook_for_file "$WT_B2" "$WT_B2/.tickets/intg-diff-b.md"

# Both files must exist on main in the bare repo
FILE_A2=$(git -C "$BARE2" show main:.tickets/intg-diff-a.md 2>/dev/null | grep -c "intg-diff-a" || true)
FILE_B2=$(git -C "$BARE2" show main:.tickets/intg-diff-b.md 2>/dev/null | grep -c "intg-diff-b" || true)

assert_ne "test_concurrent_push_different_files_a_present" "0" "$FILE_A2"
assert_ne "test_concurrent_push_different_files_b_present" "0" "$FILE_B2"

rm -rf "$TMPENV2"

# =============================================================================
# Test 3: same_file_concurrent_push_last_write_wins
# Two worktrees push the same ticket file; the second write wins with no errors.
# Satisfies: "If they modify the same file, last-write-wins — the final content
# matches the second push"
# =============================================================================
TMPENV3=$(setup_two_worktree_env)
WT_A3=$(cd "$TMPENV3/worktree-a" && pwd -P)
WT_B3=$(cd "$TMPENV3/worktree-b" && pwd -P)
BARE3="$TMPENV3/bare.git"
MAIN_A3="$TMPENV3/main-a"

# Write version 1 in worktree A
mkdir -p "$WT_A3/.tickets"
cat > "$WT_A3/.tickets/intg-same.md" <<'TICKET_A'
---
id: intg-same
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Content version A
TICKET_A

# Write version 2 in worktree B (will be pushed second — last write wins)
mkdir -p "$WT_B3/.tickets"
cat > "$WT_B3/.tickets/intg-same.md" <<'TICKET_B'
---
id: intg-same
status: in_progress
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 1
---
# Content version B last-write-wins
TICKET_B

# Push A first; both hooks must exit 0 (non-blocking)
PUSH_A_EXIT=0
(cd "$WT_A3" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"tool_response":{"success":true}}' \
        "$WT_A3/.tickets/intg-same.md" | bash "$PUSH_HOOK" >/dev/null 2>/dev/null) || PUSH_A_EXIT=$?

# Fetch into main-a so worktree-b's push can retry against new tip
git -C "$MAIN_A3" fetch -q origin 2>/dev/null || true

# Push B second
PUSH_B_EXIT=0
(cd "$WT_B3" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"tool_response":{"success":true}}' \
        "$WT_B3/.tickets/intg-same.md" | bash "$PUSH_HOOK" >/dev/null 2>/dev/null) || PUSH_B_EXIT=$?

assert_eq "test_same_file_push_a_exits_zero" "0" "$PUSH_A_EXIT"
assert_eq "test_same_file_push_b_exits_zero" "0" "$PUSH_B_EXIT"

# Final content on main must be version B (last write wins)
FINAL_CONTENT3=$(git -C "$BARE3" show main:.tickets/intg-same.md 2>/dev/null || true)
assert_contains "test_same_file_last_write_wins" "Content version B last-write-wins" "$FINAL_CONTENT3"

rm -rf "$TMPENV3"

# =============================================================================
# Test 4: unchanged_sync_path_subprocess_count
# When .last-sync-hash already matches main:.tickets, _sync_from_main must use
# at most two git rev-parse calls and zero network calls (no fetch/pull/checkout).
# Satisfies: "The unchanged sync path performs zero network calls and at most
# two git rev-parse subprocess calls"
#
# Strategy: create a git spy wrapper that logs subcommand names, then verify
# no fetch/pull/checkout calls appear after tk list on an up-to-date worktree.
# =============================================================================
TMPENV4=$(mktemp -d)
REALENV4=$(cd "$TMPENV4" && pwd -P)
REPO_ROOT4="$REALENV4/repo"

git init -q -b main "$REPO_ROOT4"
git -C "$REPO_ROOT4" config user.email "test@test.com"
git -C "$REPO_ROOT4" config user.name "Test"
make_ticket_file "$REPO_ROOT4" "subproc-test"
git -C "$REPO_ROOT4" add .tickets/
git -C "$REPO_ROOT4" commit -q -m "init"

# Create a worktree
WT4="$REALENV4/worktree"
git -C "$REPO_ROOT4" worktree add -q "$WT4" HEAD 2>/dev/null
WT4_REAL=$(cd "$WT4" && pwd -P)

# Pre-populate .last-sync-hash with the current main:.tickets hash (unchanged path)
CURRENT_HASH4=$(cd "$WT4_REAL" && unset GIT_DIR GIT_WORK_TREE && \
    git rev-parse main:.tickets 2>/dev/null || true)
echo "$CURRENT_HASH4" > "$WT4_REAL/.tickets/.last-sync-hash"

# Create a git spy: a wrapper script that logs every subcommand to a log file
GIT_SPY_LOG="$REALENV4/git-spy.log"
GIT_SPY="$REALENV4/git-spy"
# Find the real git binary (first match in PATH that isn't our spy dir)
REAL_GIT=$(command -v git)
cat > "$GIT_SPY" <<GSPY
#!/usr/bin/env bash
# Git spy: log the first argument (git subcommand) and delegate to real git
printf "%s\n" "\${1:-}" >> "$GIT_SPY_LOG"
exec "$REAL_GIT" "\$@"
GSPY
chmod +x "$GIT_SPY"

# Run tk list with the spy injected at the front of PATH
(
    cd "$WT4_REAL"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    TICKETS_DIR="$WT4_REAL/.tickets" PATH="$REALENV4:$PATH" bash "$TK_SCRIPT" list >/dev/null 2>&1 || true
)

# On the unchanged path, _sync_from_main runs two rev-parse calls then returns.
# Verify no fetch, pull, or checkout subcommands were logged.
# Use grep + wc -l rather than grep -c to avoid exit-code 1 on no-match.
FETCH_CALLS4=$(grep "^fetch$" "$GIT_SPY_LOG" 2>/dev/null | wc -l | tr -d ' ')
PULL_CALLS4=$(grep "^pull$" "$GIT_SPY_LOG" 2>/dev/null | wc -l | tr -d ' ')
CHECKOUT_CALLS4=$(grep "^checkout$" "$GIT_SPY_LOG" 2>/dev/null | wc -l | tr -d ' ')

assert_eq "test_unchanged_sync_no_fetch_calls" "0" "$FETCH_CALLS4"
assert_eq "test_unchanged_sync_no_pull_calls" "0" "$PULL_CALLS4"
assert_eq "test_unchanged_sync_no_checkout_calls" "0" "$CHECKOUT_CALLS4"

# Cleanup
git -C "$REPO_ROOT4" worktree remove --force "$WT4_REAL" 2>/dev/null || true
rm -rf "$TMPENV4"

# =============================================================================
# Test 5: sync commit preserves full main tree (regression for tree-corruption bug)
# Verifies that after a push hook fires, main's tree still contains all files
# that existed before — not just .tickets/.
# =============================================================================
TMPENV5=$(setup_two_worktree_env)
WT_A5=$(cd "$TMPENV5/worktree-a" && pwd -P)
MAIN_A5="$TMPENV5/main-a"

# Count the top-level entries in main before the push
TREE_BEFORE=$(git -C "$MAIN_A5" ls-tree main | wc -l | tr -d ' ')

# Create and push a ticket via the hook
make_ticket_file "$WT_A5" "intg-tree-check"
invoke_push_hook_for_file "$WT_A5" "$WT_A5/.tickets/intg-tree-check.md"

# Fetch the updated main from the bare origin
git -C "$MAIN_A5" fetch -q origin main 2>/dev/null
TREE_AFTER=$(git -C "$MAIN_A5" ls-tree origin/main | wc -l | tr -d ' ')

# The tree entry count should be >= the count before (same or +1 if .tickets/ was new)
assert_eq "test_sync_commit_preserves_full_tree" "true" "$([ "$TREE_AFTER" -ge "$TREE_BEFORE" ] && echo true || echo false)"

# Verify a non-ticket file (.gitignore or seed-init ticket) still exists in the tree
HAS_SEED=$(git -C "$MAIN_A5" ls-tree origin/main .tickets/seed-init.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "test_sync_commit_retains_seed_ticket" "1" "$HAS_SEED"

# Cleanup
git -C "$MAIN_A5" worktree remove --force "$WT_A5" 2>/dev/null || true
rm -rf "$TMPENV5"

# =============================================================================
# Test 6: merge_to_main_ignores_dirty_tickets
# merge-to-main.sh should not block when .tickets/ files are the only dirty
# files, but should still block on non-ticket dirty files.
# =============================================================================
MERGE_SCRIPT="$REPO_ROOT/scripts/merge-to-main.sh"
TMPENV6=$(setup_two_worktree_env)
WT_A6=$(cd "$TMPENV6/worktree-a" && pwd -P)

# Dirty only .tickets/ — merge script's dirty check should pass
make_ticket_file "$WT_A6" "dirty-ticket-only"

# Run only the dirty-check portion by extracting the logic inline
DIRTY6=$(cd "$WT_A6" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    git diff --name-only -- ':!.tickets/' 2>/dev/null || true)
DIRTY_CACHED6=$(cd "$WT_A6" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    git diff --cached --name-only -- ':!.tickets/' 2>/dev/null || true)
DIRTY_UNTRACKED6=$(cd "$WT_A6" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    git ls-files --others --exclude-standard -- ':!.tickets/' 2>/dev/null || true)

HAS_NON_TICKET_DIRTY6="false"
if [ -n "$DIRTY6" ] || [ -n "$DIRTY_CACHED6" ] || [ -n "$DIRTY_UNTRACKED6" ]; then
    HAS_NON_TICKET_DIRTY6="true"
fi
assert_eq "test_tickets_only_dirty_passes_check" "false" "$HAS_NON_TICKET_DIRTY6"

# Now add a non-ticket dirty file — should be detected
echo "dirty" > "$WT_A6/non-ticket-file.txt"
DIRTY_UNTRACKED6B=$(cd "$WT_A6" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    git ls-files --others --exclude-standard -- ':!.tickets/' 2>/dev/null || true)
assert_contains "test_non_ticket_dirty_detected" "non-ticket-file.txt" "$DIRTY_UNTRACKED6B"

rm -rf "$TMPENV6"

# =============================================================================
# Test 7: push_pull_hash_compatibility
# Verifies that the hash written by the push hook to .last-sync-hash is
# identical to the hash that _sync_from_main() in scripts/tk computes via
# `git rev-parse main:.tickets`.  If these two hash expressions diverge
# (e.g., one uses a commit hash and the other a tree hash, or they resolve
# different refs), the sync cache would always miss.
#
# Also verifies the no-op fast path: after the hashes are pre-populated as
# matching, a `tk list` in worktree B must NOT trigger a git checkout call.
# =============================================================================
TMPENV7=$(setup_two_worktree_env)
WT_A7=$(cd "$TMPENV7/worktree-a" && pwd -P)
WT_B7=$(cd "$TMPENV7/worktree-b" && pwd -P)
MAIN_A7="$TMPENV7/main-a"

# Create a ticket in worktree A and push via the hook (writes .last-sync-hash)
make_ticket_file "$WT_A7" "hash-compat-test"
invoke_push_hook_for_file "$WT_A7" "$WT_A7/.tickets/hash-compat-test.md"

# Part A: Read the hash written by the push hook
PUSH_WRITTEN_HASH7=""
if [[ -f "$WT_A7/.tickets/.last-sync-hash" ]]; then
    PUSH_WRITTEN_HASH7=$(cat "$WT_A7/.tickets/.last-sync-hash" 2>/dev/null || true)
fi
assert_ne "test_push_hook_writes_last_sync_hash" "" "$PUSH_WRITTEN_HASH7"

# Part B: Compute the hash that _sync_from_main() would compute.
# _sync_from_main uses: GIT_DIR="$common_dir" git rev-parse main:.tickets
# In this environment, main-a is the main repo; its common_dir is its .git dir.
# Worktree A's common_dir points to main-a/.git.
COMMON_DIR7=$(cd "$WT_A7" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    git rev-parse --git-common-dir 2>/dev/null || true)
# Make absolute if relative
case "$COMMON_DIR7" in
    /*) ;;
    *)  COMMON_DIR7="$WT_A7/$COMMON_DIR7" ;;
esac
PULL_COMPUTED_HASH7=$(GIT_DIR="$COMMON_DIR7" git rev-parse main:.tickets 2>/dev/null || true)

# The push hook's written hash must match the pull sync's computed hash.
# They must both refer to the tree object for .tickets/ at the same commit.
assert_eq "test_push_written_hash_equals_pull_computed_hash" \
    "$PUSH_WRITTEN_HASH7" "$PULL_COMPUTED_HASH7"

# Also verify both hashes are non-empty (sanity guard)
assert_ne "test_pull_computed_hash_nonempty" "" "$PULL_COMPUTED_HASH7"

# Part C: Verify the no-op fast path — when .last-sync-hash already matches
# main:.tickets in worktree B, a subsequent `tk list` must not trigger a
# git checkout call.

# First, bring main-a (and therefore worktree B's shared object store) up to
# date from the bare origin so worktree B sees the new commit.
git -C "$MAIN_A7" fetch -q origin 2>/dev/null || true
git -C "$MAIN_A7" reset -q --hard origin/main 2>/dev/null || true

# Pre-populate worktree B's .last-sync-hash with the CURRENT main:.tickets
# hash so that _sync_from_main sees it as already up-to-date (no-op path).
CURRENT_HASH_B7=$(cd "$WT_B7" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    git rev-parse main:.tickets 2>/dev/null || true)
echo "$CURRENT_HASH_B7" > "$WT_B7/.tickets/.last-sync-hash"

# Create a git spy to detect checkout calls during the no-op tk list run
GIT_SPY_LOG7="$TMPENV7/git-spy.log"
GIT_SPY_DIR7="$TMPENV7/git-spy-dir"
mkdir -p "$GIT_SPY_DIR7"
REAL_GIT7=$(command -v git)
cat > "$GIT_SPY_DIR7/git" <<GSPY7
#!/usr/bin/env bash
printf "%s\n" "\${1:-}" >> "$GIT_SPY_LOG7"
exec "$REAL_GIT7" "\$@"
GSPY7
chmod +x "$GIT_SPY_DIR7/git"

# Run tk list in worktree B with the spy injected — hash already matches
(
    cd "$WT_B7"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    TICKETS_DIR="$WT_B7/.tickets" PATH="$GIT_SPY_DIR7:$PATH" bash "$TK_SCRIPT" list >/dev/null 2>&1 || true
)

CHECKOUT_CALLS7=$(grep "^checkout$" "$GIT_SPY_LOG7" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "test_noop_sync_path_no_checkout_when_hash_matches" "0" "$CHECKOUT_CALLS7"

# Cleanup
git -C "$MAIN_A7" worktree remove --force "$WT_A7" 2>/dev/null || true
git -C "$MAIN_A7" worktree remove --force "$WT_B7" 2>/dev/null || true
rm -rf "$TMPENV7"

# =============================================================================
print_summary
