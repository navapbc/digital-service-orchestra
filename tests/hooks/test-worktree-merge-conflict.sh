#!/usr/bin/env bash
# tests/hooks/test-worktree-merge-conflict.sh
# Tests for worktree merge conflict detection and escalation behavior.
#
# Scenario: Multiple worktrees are being merged into a session branch
# (per-worktree-review-commit.md Step 5-6). When a merge conflict occurs:
#   - git merge --abort is run (conflict worktree is NOT removed)
#   - The merge is flagged for re-implementation (CONFLICT comment)
#   - Other non-conflicting worktrees continue to merge successfully
#
# These are structural lifecycle tests — they test git lifecycle behavior
# (conflict detection, abort, merge success) using real git repos + worktrees.
# They do NOT test unwritten production code; the assertions are against git
# and filesystem state, not against functions that do not exist yet.
#
# Tests:
#  1. test_conflict_creates_ticket_comment
#     - Two worktrees both modify the same file with conflicting content.
#     - Merge worktree-1 (succeeds). Attempt to merge worktree-2 (conflicts).
#     - Assert: merge exits non-zero, git merge --abort succeeds,
#       and the worktree-2 directory is retained (not removed).
#
#  2. test_non_conflicting_worktrees_continue
#     - After a conflict with worktree-2, worktree-3 modifies a different file.
#     - Assert: merging worktree-3 succeeds (exit 0).
#
#  3. test_conflicting_worktree_queued
#     - After all non-conflicting merges complete, the conflicting worktree
#       directory still exists (retained for re-implementation).
#     - Assert: worktree-2 directory still present after session processing.
#
# Usage: bash tests/hooks/test-worktree-merge-conflict.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-merge-conflict.sh ==="

# ── Cleanup on exit ───────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        # Prune any linked worktrees before removing tmpdir
        git -C "$d/session" worktree prune 2>/dev/null || true
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: make a multi-worktree conflict scenario ───────────────────────────
# Creates a repo that simulates an orchestrator session branch with multiple
# worktrees being merged in sequence. Worktree-1 and Worktree-2 both modify
# the same file (shared.txt) with conflicting content. Worktree-3 modifies
# a different file (unique3.txt) — no conflict.
#
# Structure:
#   $tmpdir/origin.git     — bare remote
#   $tmpdir/session        — session branch (HEAD receives merges)
#   $tmpdir/wt1            — linked worktree-1 (modifies shared.txt — will succeed)
#   $tmpdir/wt2            — linked worktree-2 (modifies shared.txt — will conflict)
#   $tmpdir/wt3            — linked worktree-3 (modifies unique3.txt — no conflict)
#
# State on return: all three worktree branches have commits but nothing has
# been merged into session yet (session is at the shared base commit).
# Returns: $tmpdir on stdout.
_make_conflict_scenario_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    # Create bare remote
    git init --bare -b main "$tmpdir/origin.git" --quiet 2>/dev/null || \
        git init --bare "$tmpdir/origin.git" --quiet

    # Clone into session directory
    git clone "$tmpdir/origin.git" "$tmpdir/session" --quiet 2>/dev/null
    git -C "$tmpdir/session" config user.email "test@test.com"
    git -C "$tmpdir/session" config user.name "Test"

    # Initial commit — shared.txt has a base value both wt1 and wt2 will change
    echo "shared base content" > "$tmpdir/session/shared.txt"
    echo "session-only content" > "$tmpdir/session/session.txt"
    git -C "$tmpdir/session" add shared.txt session.txt
    git -C "$tmpdir/session" commit -m "initial: add shared.txt and session.txt" --quiet
    git -C "$tmpdir/session" push origin main --quiet 2>/dev/null

    # Create three worktree branches from the same base commit
    git -C "$tmpdir/session" branch wt-branch-1 --quiet
    git -C "$tmpdir/session" branch wt-branch-2 --quiet
    git -C "$tmpdir/session" branch wt-branch-3 --quiet

    # Add linked git worktrees
    git -C "$tmpdir/session" worktree add "$tmpdir/wt1" wt-branch-1 --quiet 2>/dev/null
    git -C "$tmpdir/session" worktree add "$tmpdir/wt2" wt-branch-2 --quiet 2>/dev/null
    git -C "$tmpdir/session" worktree add "$tmpdir/wt3" wt-branch-3 --quiet 2>/dev/null

    for wt in wt1 wt2 wt3; do
        git -C "$tmpdir/$wt" config user.email "test@test.com"
        git -C "$tmpdir/$wt" config user.name "Test"
    done

    # Worktree-1: modifies shared.txt (will be merged first — creates session state)
    echo "shared content — wt1 implementation" > "$tmpdir/wt1/shared.txt"
    git -C "$tmpdir/wt1" add shared.txt
    git -C "$tmpdir/wt1" commit -m "feat(wt1): implement shared.txt" --quiet

    # Worktree-2: modifies shared.txt differently (will conflict after wt1 is merged)
    echo "shared content — wt2 CONFLICTING implementation" > "$tmpdir/wt2/shared.txt"
    git -C "$tmpdir/wt2" add shared.txt
    git -C "$tmpdir/wt2" commit -m "feat(wt2): implement shared.txt differently" --quiet

    # Worktree-3: modifies a unique file only (no conflict with any branch)
    echo "unique content from wt3" > "$tmpdir/wt3/unique3.txt"
    git -C "$tmpdir/wt3" add unique3.txt
    git -C "$tmpdir/wt3" commit -m "feat(wt3): add unique3.txt" --quiet

    echo "$tmpdir"
}

# =============================================================================
# Test 1: test_conflict_creates_ticket_comment
# =============================================================================
# Simulates the per-worktree-review-commit.md Step 5-6 flow:
#   - Merge worktree-1 into session (succeeds)
#   - Attempt to merge worktree-2 (conflicts)
#   - Assert: merge exit code is non-zero
#   - Run git merge --abort: assert it succeeds (exit 0)
#   - Worktree-2 directory is NOT removed after abort
#
# The "ticket comment" aspect: in production, the orchestrator writes a ticket
# comment "CONFLICT: worktree <id> blocked". Since we cannot call the ticket
# CLI in unit tests, we verify the structural preconditions that make the
# comment necessary: a real conflict (non-zero merge exit), successful abort,
# and retained worktree directory.
test_conflict_creates_ticket_comment() {
    _snapshot_fail

    local tmpdir session_repo wt1_sha wt2_sha merge1_exit merge2_exit abort_exit
    tmpdir=$(cd /tmp && _make_conflict_scenario_repo)
    session_repo="$tmpdir/session"

    # ── Step 1: Merge worktree-1 into session (should succeed) ────────────────
    wt1_sha=$(git -C "$tmpdir/wt1" rev-parse HEAD)
    merge1_exit=0
    git -C "$session_repo" merge "$wt1_sha" --no-edit --quiet 2>/dev/null || merge1_exit=$?

    assert_eq "test_conflict_creates_ticket_comment: wt1 merge succeeds (exit 0)" \
        "0" "$merge1_exit"

    # Verify session now contains wt1's version of shared.txt
    local shared_content
    shared_content=$(cat "$session_repo/shared.txt" 2>/dev/null || echo "MISSING")
    assert_contains "test_conflict_creates_ticket_comment: session has wt1 content after wt1 merge" \
        "wt1 implementation" "$shared_content"

    # ── Step 2: Attempt to merge worktree-2 (should conflict) ─────────────────
    wt2_sha=$(git -C "$tmpdir/wt2" rev-parse HEAD)
    merge2_exit=0
    git -C "$session_repo" merge "$wt2_sha" --no-edit --quiet 2>/dev/null || merge2_exit=$?

    assert_ne "test_conflict_creates_ticket_comment: wt2 merge fails with conflict (exit != 0)" \
        "0" "$merge2_exit"

    # Verify MERGE_HEAD exists (git is in conflict state)
    local merge_head_present
    merge_head_present=$(test -f "$session_repo/.git/MERGE_HEAD" && echo "1" || echo "0")
    assert_eq "test_conflict_creates_ticket_comment: MERGE_HEAD present after conflict" \
        "1" "$merge_head_present"

    # ── Step 3: Abort the conflicting merge ───────────────────────────────────
    abort_exit=0
    git -C "$session_repo" merge --abort 2>/dev/null || abort_exit=$?

    assert_eq "test_conflict_creates_ticket_comment: git merge --abort succeeds (exit 0)" \
        "0" "$abort_exit"

    # Verify MERGE_HEAD is gone after abort
    local merge_head_gone
    merge_head_gone=$(test -f "$session_repo/.git/MERGE_HEAD" && echo "1" || echo "0")
    assert_eq "test_conflict_creates_ticket_comment: MERGE_HEAD absent after abort" \
        "0" "$merge_head_gone"

    # ── Step 4: Worktree-2 directory is retained (not removed) ────────────────
    # Protocol: DO NOT remove the worktree on conflict. Retain for re-implementation.
    local wt2_dir_present
    wt2_dir_present=$(test -d "$tmpdir/wt2" && echo "1" || echo "0")
    assert_eq "test_conflict_creates_ticket_comment: wt2 directory retained after conflict abort" \
        "1" "$wt2_dir_present"

    # wt2's branch commit still exists (retained for re-implementation)
    local wt2_commit_still_exists
    wt2_commit_still_exists=$(git -C "$session_repo" cat-file -t "$wt2_sha" 2>/dev/null || echo "MISSING")
    assert_eq "test_conflict_creates_ticket_comment: wt2 branch commit still accessible (for re-implementation)" \
        "commit" "$wt2_commit_still_exists"

    assert_pass_if_clean "test_conflict_creates_ticket_comment"
}

# =============================================================================
# Test 2: test_non_conflicting_worktrees_continue
# =============================================================================
# After a conflict with worktree-2 (aborted), worktree-3 modifies a completely
# different file (unique3.txt). Assert that merging worktree-3 into session
# succeeds (exit 0) and its file appears in session.
#
# This validates the protocol in per-worktree-review-commit.md Step 6:
# "Continue to next worktree" after a conflict abort.
test_non_conflicting_worktrees_continue() {
    _snapshot_fail

    local tmpdir session_repo wt1_sha wt2_sha wt3_sha merge_exit
    tmpdir=$(cd /tmp && _make_conflict_scenario_repo)
    session_repo="$tmpdir/session"

    # ── Setup: merge wt1, conflict+abort wt2 (simulate earlier processing) ────
    wt1_sha=$(git -C "$tmpdir/wt1" rev-parse HEAD)
    git -C "$session_repo" merge "$wt1_sha" --no-edit --quiet 2>/dev/null

    wt2_sha=$(git -C "$tmpdir/wt2" rev-parse HEAD)
    git -C "$session_repo" merge "$wt2_sha" --no-edit --quiet 2>/dev/null || true
    git -C "$session_repo" merge --abort 2>/dev/null || true

    # Verify we are in a clean state after the abort (prerequisite for wt3)
    local status_clean
    status_clean=$(git -C "$session_repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "test_non_conflicting_worktrees_continue: session is clean after wt2 abort" \
        "0" "$status_clean"

    # ── Merge worktree-3 (no conflict — different file) ───────────────────────
    wt3_sha=$(git -C "$tmpdir/wt3" rev-parse HEAD)
    merge_exit=0
    git -C "$session_repo" merge "$wt3_sha" --no-edit --quiet 2>/dev/null || merge_exit=$?

    assert_eq "test_non_conflicting_worktrees_continue: wt3 merge succeeds after wt2 conflict (exit 0)" \
        "0" "$merge_exit"

    # Verify wt3's unique file is now in session
    local unique3_present
    unique3_present=$(test -f "$session_repo/unique3.txt" && echo "1" || echo "0")
    assert_eq "test_non_conflicting_worktrees_continue: unique3.txt present in session after wt3 merge" \
        "1" "$unique3_present"

    # Verify wt1's content is still intact in session (wt3 merge didn't break it)
    local shared_content
    shared_content=$(cat "$session_repo/shared.txt" 2>/dev/null || echo "MISSING")
    assert_contains "test_non_conflicting_worktrees_continue: wt1 content preserved after wt3 merge" \
        "wt1 implementation" "$shared_content"

    # Verify no MERGE_HEAD (clean state after wt3 merge)
    local merge_head_gone
    merge_head_gone=$(test -f "$session_repo/.git/MERGE_HEAD" && echo "1" || echo "0")
    assert_eq "test_non_conflicting_worktrees_continue: no pending MERGE_HEAD after wt3 merge" \
        "0" "$merge_head_gone"

    assert_pass_if_clean "test_non_conflicting_worktrees_continue"
}

# =============================================================================
# Test 3: test_conflicting_worktree_queued
# =============================================================================
# After all non-conflicting merges complete (wt1 merged, wt3 merged, wt2 aborted),
# the conflicting worktree-2 directory still exists.
# This verifies the "Worktree Retention Protocol" from per-worktree-review-commit.md:
# "Do NOT remove a worktree until its merge is complete. Worktrees with conflicts
# are retained for re-implementation."
#
# Assert: wt2 directory present, wt2 branch commit accessible, wt3 removed
# (since it was successfully merged — in production it would be pruned via
# `git worktree remove --force`).
test_conflicting_worktree_queued() {
    _snapshot_fail

    local tmpdir session_repo wt1_sha wt2_sha wt3_sha
    tmpdir=$(cd /tmp && _make_conflict_scenario_repo)
    session_repo="$tmpdir/session"

    # ── Simulate full session processing: merge wt1, conflict+abort wt2, merge wt3 ──
    wt1_sha=$(git -C "$tmpdir/wt1" rev-parse HEAD)
    git -C "$session_repo" merge "$wt1_sha" --no-edit --quiet 2>/dev/null

    wt2_sha=$(git -C "$tmpdir/wt2" rev-parse HEAD)
    git -C "$session_repo" merge "$wt2_sha" --no-edit --quiet 2>/dev/null || true
    # Abort the conflict
    git -C "$session_repo" merge --abort 2>/dev/null || true

    wt3_sha=$(git -C "$tmpdir/wt3" rev-parse HEAD)
    git -C "$session_repo" merge "$wt3_sha" --no-edit --quiet 2>/dev/null

    # Simulate successful-merge cleanup: remove wt1 and wt3 (production uses
    # `git worktree remove --force`). wt2 is NOT removed — conflict retention.
    git -C "$session_repo" worktree remove --force "$tmpdir/wt1" 2>/dev/null || true
    git -C "$session_repo" worktree remove --force "$tmpdir/wt3" 2>/dev/null || true

    # ── Assert: conflicting worktree-2 directory still exists ─────────────────
    local wt2_dir_present
    wt2_dir_present=$(test -d "$tmpdir/wt2" && echo "1" || echo "0")
    assert_eq "test_conflicting_worktree_queued: wt2 directory retained (conflict worktree not removed)" \
        "1" "$wt2_dir_present"

    # wt2 branch commit still reachable (needed for re-implementation)
    local wt2_commit_type
    wt2_commit_type=$(git -C "$session_repo" cat-file -t "$wt2_sha" 2>/dev/null || echo "MISSING")
    assert_eq "test_conflicting_worktree_queued: wt2 commit still accessible for re-implementation" \
        "commit" "$wt2_commit_type"

    # wt2 branch still listed in worktree list (not pruned)
    local wt2_in_worktree_list
    wt2_in_worktree_list=$(git -C "$session_repo" worktree list 2>/dev/null | grep -c "wt-branch-2" || echo "0")
    assert_ne "test_conflicting_worktree_queued: wt2 branch still in git worktree list" \
        "0" "$wt2_in_worktree_list"

    # ── Assert: successfully-merged worktrees are cleaned up ──────────────────
    # wt1 directory removed (successful merge → cleanup per Step 7)
    local wt1_dir_present
    wt1_dir_present=$(test -d "$tmpdir/wt1" && echo "1" || echo "0")
    assert_eq "test_conflicting_worktree_queued: wt1 directory removed after successful merge" \
        "0" "$wt1_dir_present"

    # wt3 directory removed (successful merge → cleanup per Step 7)
    local wt3_dir_present
    wt3_dir_present=$(test -d "$tmpdir/wt3" && echo "1" || echo "0")
    assert_eq "test_conflicting_worktree_queued: wt3 directory removed after successful merge" \
        "0" "$wt3_dir_present"

    # ── Assert: session contains wt1 and wt3 work (but NOT wt2) ──────────────
    local shared_content
    shared_content=$(cat "$session_repo/shared.txt" 2>/dev/null || echo "MISSING")
    assert_contains "test_conflicting_worktree_queued: session has wt1 content (shared.txt)" \
        "wt1 implementation" "$shared_content"

    local unique3_present
    unique3_present=$(test -f "$session_repo/unique3.txt" && echo "1" || echo "0")
    assert_eq "test_conflicting_worktree_queued: session has wt3 content (unique3.txt)" \
        "1" "$unique3_present"

    # wt2's conflicting content did NOT make it into session
    local wt2_content_in_session
    wt2_content_in_session="0"
    grep -q "CONFLICTING implementation" "$session_repo/shared.txt" 2>/dev/null && wt2_content_in_session="1" || true
    assert_eq "test_conflicting_worktree_queued: wt2 conflicting content NOT in session" \
        "0" "$wt2_content_in_session"

    assert_pass_if_clean "test_conflicting_worktree_queued"
}

# =============================================================================
# Run all tests
# =============================================================================
echo ""
test_conflict_creates_ticket_comment
echo ""
test_non_conflicting_worktrees_continue
echo ""
test_conflicting_worktree_queued

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
