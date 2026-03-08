#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-merge-to-main-tickets.sh
# Integration tests for merge-to-main.sh .tickets/ handling.
#
# Tests cover:
#   1. skip-worktree flags cleared before stash detection
#   2. .tickets/ changes correctly stashed before merge
#   3. .tickets/ merge conflicts auto-resolved (worktree wins / branch wins)
#   4. stash pop conflict resolution works (worktree wins)
#   5. clean merge succeeds with dirty .tickets/
#   6. worktree sync auto-resolves ticket conflicts (--ours)
#   7. main-repo force-clean succeeds with skip-worktree + dirty .tickets/
#
# Usage: bash lockpick-workflow/tests/hooks/test-merge-to-main-tickets.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_SCRIPT="$REPO_ROOT/scripts/merge-to-main.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── Helper: create a minimal ticket file ─────────────────────────────────────
make_ticket_file() {
    local dir="$1"
    local ticket_id="$2"
    local extra_content="${3:-}"
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
# Ticket $ticket_id
$extra_content
EOF
}

# ── Helper: set up a merge-to-main test environment ──────────────────────────
# Creates:
#   $REALENV/bare.git       — bare repo acting as "origin"
#   $REALENV/main-clone/    — main repo cloned from bare (main checked out)
#   $REALENV/worktree/      — worktree linked from main-clone on a feature branch
#
# The worktree has .git as a FILE (correct for worktrees), so merge-to-main.sh's
# [ -d .git ] check will correctly not reject it.
#
# Outputs the canonicalized env root to stdout.
setup_merge_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo with initial commit
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    # Create a non-ticket file so the repo has content beyond .tickets/
    echo "initial" > "$REALENV/seed/README.md"
    make_ticket_file "$REALENV/seed" "seed-init"
    git -C "$REALENV/seed" add -A
    git -C "$REALENV/seed" commit -q -m "init"

    # 2. Bare repo cloned from seed (acts as origin)
    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"

    # 3. Clone bare into main-clone
    git clone -q "$REALENV/bare.git" "$REALENV/main-clone"
    git -C "$REALENV/main-clone" config user.email "test@test.com"
    git -C "$REALENV/main-clone" config user.name "Test"

    # 4. Create a feature branch worktree
    git -C "$REALENV/main-clone" branch feature-branch 2>/dev/null || true
    git -C "$REALENV/main-clone" worktree add -q "$REALENV/worktree" feature-branch 2>/dev/null
    git -C "$REALENV/worktree" config user.email "test@test.com"
    git -C "$REALENV/worktree" config user.name "Test"

    echo "$REALENV"
}

# ── Helper: cleanup ──────────────────────────────────────────────────────────
cleanup_env() {
    local env_dir="$1"
    git -C "$env_dir/main-clone" worktree remove --force "$env_dir/worktree" 2>/dev/null || true
    rm -rf "$env_dir"
}

# =============================================================================
# Test 1: skip-worktree flags cleared before stash detection
# When skip-worktree is set on .tickets/ files, merge-to-main.sh must clear
# those flags so that git diff/stash can detect the modified files.
# =============================================================================
TMPENV1=$(setup_merge_env)
WT1=$(cd "$TMPENV1/worktree" && pwd -P)

# Make a committed change on the feature branch so merge has something to do
echo "feature work" > "$WT1/feature.txt"
(cd "$WT1" && git add feature.txt && git commit -q -m "feat: add feature")

# Create a dirty ticket file in the worktree
make_ticket_file "$WT1" "skip-worktree-test" "modified content"

# Set skip-worktree on the ticket file (simulates what ticket-sync-push does)
(cd "$WT1" && git add .tickets/skip-worktree-test.md 2>/dev/null && \
    git update-index --skip-worktree .tickets/skip-worktree-test.md 2>/dev/null || true)

# Verify skip-worktree IS set before running the script
SW_BEFORE=$(cd "$WT1" && git ls-files -v -- .tickets/ 2>/dev/null | grep '^S ' | wc -l | tr -d ' ')
assert_ne "test_skip_worktree_set_before_merge" "0" "$SW_BEFORE"

# Run merge-to-main.sh — it should clear skip-worktree, stash, merge, and succeed
MERGE_OUTPUT1=$(cd "$WT1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# After merge completes, skip-worktree flags should be cleared (script clears them)
# Check on main-clone (where the main-side logic runs)
MAIN1="$TMPENV1/main-clone"
SW_AFTER=$(cd "$MAIN1" && git ls-files -v -- .tickets/ 2>/dev/null | grep '^S ' | wc -l | tr -d ' ')
assert_eq "test_skip_worktree_cleared_on_main" "0" "$SW_AFTER"

# Merge should have succeeded (DONE message present)
assert_contains "test_skip_worktree_merge_succeeds" "DONE" "$MERGE_OUTPUT1"

cleanup_env "$TMPENV1"

# =============================================================================
# Test 2: .tickets/ changes correctly stashed before merge
# Dirty .tickets/ files in the worktree should not block the merge — they are
# stashed before the merge and restored after.
# =============================================================================
TMPENV2=$(setup_merge_env)
WT2=$(cd "$TMPENV2/worktree" && pwd -P)

# Make a committed change on the feature branch
echo "feature work 2" > "$WT2/feature2.txt"
(cd "$WT2" && git add feature2.txt && git commit -q -m "feat: add feature2")

# Create dirty (untracked) ticket files in the worktree
make_ticket_file "$WT2" "stash-test-a" "worktree version A"
make_ticket_file "$WT2" "stash-test-b" "worktree version B"

# Run merge-to-main.sh
MERGE_OUTPUT2=$(cd "$WT2" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Verify the stash message appeared (tickets were detected and stashed)
assert_contains "test_tickets_stashed_before_merge" "Stashing .tickets/" "$MERGE_OUTPUT2"

# Merge should succeed
assert_contains "test_stash_merge_succeeds" "DONE" "$MERGE_OUTPUT2"

# After merge, the ticket files should still exist in the worktree
# (restored from stash)
TICKET_A_EXISTS2="false"
if [ -f "$WT2/.tickets/stash-test-a.md" ]; then
    TICKET_A_EXISTS2="true"
fi
assert_eq "test_stashed_ticket_a_restored" "true" "$TICKET_A_EXISTS2"

cleanup_env "$TMPENV2"

# =============================================================================
# Test 3: .tickets/ merge conflicts auto-resolved
# When main and worktree have conflicting .tickets/ changes, merge-to-main.sh
# should auto-resolve: worktree wins during worktree sync, branch wins during
# main merge.
# =============================================================================
TMPENV3=$(setup_merge_env)
WT3=$(cd "$TMPENV3/worktree" && pwd -P)
MAIN3="$TMPENV3/main-clone"
BARE3="$TMPENV3/bare.git"

# Create a conflicting ticket on main (via bare repo)
# First, push a change to main that modifies the same ticket
(cd "$MAIN3" && \
    make_ticket_file "$MAIN3" "conflict-test" "main version" && \
    git add .tickets/ && \
    git commit -q -m "main: add conflict-test ticket" && \
    git push -q origin main 2>/dev/null)

# Create the same ticket with different content on the feature branch
make_ticket_file "$WT3" "conflict-test" "worktree version"
(cd "$WT3" && git add .tickets/ && git commit -q -m "feat: add conflict-test ticket")

# Also add a non-ticket feature commit so merge is meaningful
echo "feature3" > "$WT3/feature3.txt"
(cd "$WT3" && git add feature3.txt && git commit -q -m "feat: add feature3")

# Run merge-to-main.sh
MERGE_OUTPUT3=$(cd "$WT3" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed with auto-resolution
assert_contains "test_conflict_merge_succeeds" "DONE" "$MERGE_OUTPUT3"

# On main, the branch version should win (--theirs in main merge)
MAIN_TICKET_CONTENT3=$(cd "$MAIN3" && git show HEAD:.tickets/conflict-test.md 2>/dev/null || true)
assert_contains "test_branch_wins_on_main" "worktree version" "$MAIN_TICKET_CONTENT3"

cleanup_env "$TMPENV3"

# =============================================================================
# Test 4: stash pop conflict resolution works without blocking merge
# When restoring stashed .tickets/ after the worktree sync merge, if there's a
# conflict, merge-to-main.sh resolves it (--ours keeps HEAD's merged state)
# and drops the stash so the merge can proceed.
# =============================================================================
TMPENV4=$(setup_merge_env)
WT4=$(cd "$TMPENV4/worktree" && pwd -P)
MAIN4="$TMPENV4/main-clone"

# Push a ticket change to main that will conflict with dirty worktree tickets
(cd "$MAIN4" && \
    make_ticket_file "$MAIN4" "stash-pop-test" "main version for pop conflict" && \
    git add .tickets/ && \
    git commit -q -m "main: add stash-pop ticket" && \
    git push -q origin main 2>/dev/null)

# Add a committed feature change on worktree branch
echo "feature4" > "$WT4/feature4.txt"
(cd "$WT4" && git add feature4.txt && git commit -q -m "feat: feature4")

# Create dirty (uncommitted) ticket in worktree with conflicting content
make_ticket_file "$WT4" "stash-pop-test" "worktree dirty version for pop"

# Run merge-to-main.sh
MERGE_OUTPUT4=$(cd "$WT4" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed — stash pop conflict must not block the merge
assert_contains "test_stash_pop_merge_succeeds" "DONE" "$MERGE_OUTPUT4"

# The ticket file should exist after merge (not lost during stash pop resolution)
TICKET_EXISTS4="false"
if [ -f "$WT4/.tickets/stash-pop-test.md" ]; then
    TICKET_EXISTS4="true"
fi
assert_eq "test_stash_pop_ticket_file_survives" "true" "$TICKET_EXISTS4"

# Stash should be clean (dropped after conflict resolution)
STASH_COUNT4=$(cd "$WT4" && git stash list 2>/dev/null | wc -l | tr -d ' ')
assert_eq "test_stash_pop_stash_cleaned" "0" "$STASH_COUNT4"

cleanup_env "$TMPENV4"

# =============================================================================
# Test 5: clean merge succeeds with dirty .tickets/
# When .tickets/ files are the only dirty files and there are no conflicts,
# the merge should succeed end-to-end.
# =============================================================================
TMPENV5=$(setup_merge_env)
WT5=$(cd "$TMPENV5/worktree" && pwd -P)

# Make committed changes on the worktree branch
echo "feature5" > "$WT5/feature5.txt"
(cd "$WT5" && git add feature5.txt && git commit -q -m "feat: feature5")

# Create dirty .tickets/ (untracked, no conflict with main)
make_ticket_file "$WT5" "clean-merge-test" "just a dirty ticket"

# Run merge-to-main.sh
MERGE_OUTPUT5=$(cd "$WT5" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should succeed completely
assert_contains "test_clean_merge_with_dirty_tickets_succeeds" "DONE" "$MERGE_OUTPUT5"

# The feature file should be on main
MAIN5="$TMPENV5/main-clone"
FEATURE_ON_MAIN5=$(cd "$MAIN5" && git show HEAD:feature5.txt 2>/dev/null || echo "NOT_FOUND")
assert_eq "test_clean_merge_feature_on_main" "feature5" "$FEATURE_ON_MAIN5"

# The dirty ticket should still exist in the worktree (not lost)
DIRTY_TICKET_EXISTS5="false"
if [ -f "$WT5/.tickets/clean-merge-test.md" ]; then
    DIRTY_TICKET_EXISTS5="true"
fi
assert_eq "test_clean_merge_dirty_ticket_preserved" "true" "$DIRTY_TICKET_EXISTS5"

cleanup_env "$TMPENV5"

# =============================================================================
# Test 6: worktree sync auto-resolves ticket conflicts (worktree wins / --ours)
# When merging origin/main into the worktree, .tickets/ conflicts should be
# resolved with --ours (worktree version wins).
# =============================================================================
TMPENV6=$(setup_merge_env)
WT6=$(cd "$TMPENV6/worktree" && pwd -P)
MAIN6="$TMPENV6/main-clone"

# Push conflicting ticket to main
(cd "$MAIN6" && \
    make_ticket_file "$MAIN6" "sync-conflict" "main says this" && \
    git add .tickets/ && \
    git commit -q -m "main: sync-conflict ticket" && \
    git push -q origin main 2>/dev/null)

# Commit conflicting ticket on worktree branch
make_ticket_file "$WT6" "sync-conflict" "worktree says this"
(cd "$WT6" && git add .tickets/ && git commit -q -m "feat: sync-conflict ticket")

# Add a non-ticket commit so the merge is meaningful
echo "feature6" > "$WT6/feature6.txt"
(cd "$WT6" && git add feature6.txt && git commit -q -m "feat: feature6")

# Run merge-to-main.sh
MERGE_OUTPUT6=$(cd "$WT6" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should succeed with auto-resolution
assert_contains "test_worktree_sync_conflict_succeeds" "DONE" "$MERGE_OUTPUT6"

# After the worktree sync merge (origin/main into worktree), the worktree
# version should win (--ours). Check the worktree's committed ticket content.
WT_TICKET6=$(cd "$WT6" && git show HEAD:.tickets/sync-conflict.md 2>/dev/null || true)
assert_contains "test_worktree_sync_ours_wins" "worktree says this" "$WT_TICKET6"

cleanup_env "$TMPENV6"

# =============================================================================
# Test 7: main-repo force-clean succeeds with skip-worktree + dirty .tickets/
# When the main repo has dirty .tickets/ files with skip-worktree set (from
# detached-index sync pushes), merge-to-main.sh must force-clean them before
# merging. This is the exact scenario that triggers the "Entry not uptodate"
# bug when stash-based cleaning fails.
# =============================================================================
TMPENV7=$(setup_merge_env)
WT7=$(cd "$TMPENV7/worktree" && pwd -P)
MAIN7="$TMPENV7/main-clone"

# Make a committed change on the feature branch
echo "feature7" > "$WT7/feature7.txt"
(cd "$WT7" && git add feature7.txt && git commit -q -m "feat: feature7")

# Simulate the state that detached-index sync creates on the main repo:
# 1. Modify .tickets/ files on disk (stale content, not matching HEAD)
# 2. Set skip-worktree so git diff/stash can't see them
(cd "$MAIN7" && \
    make_ticket_file "$MAIN7" "force-clean-test" "stale dirty content" && \
    git add .tickets/force-clean-test.md 2>/dev/null && \
    git update-index --skip-worktree .tickets/force-clean-test.md 2>/dev/null || true)

# Also create an untracked ticket (simulates new ticket from sync)
make_ticket_file "$MAIN7" "force-clean-untracked" "untracked from sync"

# Verify skip-worktree IS set on main before the merge
SW_MAIN_BEFORE7=$(cd "$MAIN7" && git ls-files -v -- .tickets/ 2>/dev/null | grep '^S ' | wc -l | tr -d ' ')
assert_ne "test_force_clean_skip_worktree_set_on_main" "0" "$SW_MAIN_BEFORE7"

# Run merge-to-main.sh — force-clean should handle the dirty main repo
MERGE_OUTPUT7=$(cd "$WT7" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed (no "Entry not uptodate" error)
assert_contains "test_force_clean_merge_succeeds" "DONE" "$MERGE_OUTPUT7"

# Skip-worktree should be cleared on main after merge
SW_MAIN_AFTER7=$(cd "$MAIN7" && git ls-files -v -- .tickets/ 2>/dev/null | grep '^S ' | wc -l | tr -d ' ')
assert_eq "test_force_clean_skip_worktree_cleared" "0" "$SW_MAIN_AFTER7"

# The feature file should be on main
FEATURE_ON_MAIN7=$(cd "$MAIN7" && git show HEAD:feature7.txt 2>/dev/null || echo "NOT_FOUND")
assert_eq "test_force_clean_feature_on_main" "feature7" "$FEATURE_ON_MAIN7"

cleanup_env "$TMPENV7"

# =============================================================================
print_summary
