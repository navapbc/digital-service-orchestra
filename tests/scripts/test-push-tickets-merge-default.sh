#!/usr/bin/env bash
# test-push-tickets-merge-default.sh
# Behavioral test for Fix 3 of bug 637b — switch _push_tickets_branch from
# rebase-first to merge-as-default reconciliation.
#
# Verifies that when a push is rejected as non-fast-forward, the tracker
# reconciles by MERGING origin/tickets (atomic, no multi-step state) rather
# than REBASING (multi-step state machine vulnerable to mid-pick
# interruption + concurrent-commit data loss).
#
# Test fixtures use local bare repos as the remote (no network).
#
# Testing mode: RED — must FAIL until _push_tickets_branch is converted.
#
# Usage: bash tests/scripts/test-push-tickets-merge-default.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-push-tickets-merge-default.sh ==="

if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$TICKET_LIB" ]; then
    echo "SKIP: ticket-lib.sh not present"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Build a fixture tracker + bare-remote where push will fail non-fast-forward.
# Layout:
#   $tmp/bare.git           — bare remote with commit B
#   $tmp/tracker            — local tracker with DIFFERENT commit C on top of A
#   Both branches diverge from common ancestor A.
_make_non_ff_fixture() {
    local tmp
    tmp=$(mktemp -d /tmp/test-push-merge.XXXXXX)
    _CLEANUP_DIRS+=("$tmp")

    # Bare remote
    git init -q --bare -b tickets "$tmp/bare.git"

    # Local tracker
    git init -q -b tickets "$tmp/tracker"
    cd "$tmp/tracker" || exit 1
    git config user.email test@test.com
    git config user.name Test
    git config commit.gpgsign false
    git config gc.auto 0

    # Common ancestor A
    echo "A" > a.txt; git add a.txt
    git commit -q -m "A (common ancestor)"

    # Push A to bare so it has tickets branch
    git remote add origin "$tmp/bare.git"
    git push -q origin tickets

    # Bare gets commit B (simulating another writer pushed first)
    # Create a temp clone, commit B, push back
    local _bare_writer="$tmp/bare-writer"
    git clone -q -b tickets "$tmp/bare.git" "$_bare_writer"
    cd "$_bare_writer" || exit 1
    git config user.email test@test.com
    git config user.name Test
    git config commit.gpgsign false
    echo "B" > b.txt; git add b.txt
    git commit -q -m "B (remote ahead)"
    git push -q origin tickets

    # Back to tracker: add diverging commit C (will fail to push non-FF)
    cd "$tmp/tracker" || exit 1
    echo "C" > c.txt; git add c.txt
    git commit -q -m "C (local diverging)"

    cd - >/dev/null || exit 1
    echo "$tmp"
}

# Resolve gitdir for a worktree
_resolve_git_dir() {
    local p="$1/.git"
    if [ -d "$p" ]; then
        echo "$p"
    elif [ -f "$p" ]; then
        sed 's/^gitdir: //' "$p"
    fi
}

# ── Test 1: _push_tickets_branch produces a merge commit (not rebase) ────────
echo "Test 1: non-FF push triggers merge (not rebase)"
test_non_ff_uses_merge() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "prereq: ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fx
    fx=$(_make_non_ff_fixture)
    local tracker="$fx/tracker"
    local pre_sha
    pre_sha=$(git -C "$tracker" rev-parse HEAD)

    (
        source "$TICKET_LIB"
        _push_tickets_branch "$tracker" >/dev/null 2>&1
    )

    local post_sha
    post_sha=$(git -C "$tracker" rev-parse HEAD)

    # The reconciliation should have produced a NEW commit (the merge commit).
    # If rebase were used, HEAD would point at a rebased version of C (a NEW
    # but non-merge commit). If merge were used, HEAD points at a merge commit
    # with TWO parents.

    # Count parents of HEAD
    local parent_count
    parent_count=$(git -C "$tracker" log -1 --pretty='%P' HEAD | wc -w | tr -d ' ')

    assert_eq "HEAD has 2 parents (merge commit)" "2" "$parent_count"

    # Verify both A→B and A→C branches are reachable from HEAD
    if git -C "$tracker" merge-base --is-ancestor "$pre_sha" HEAD; then
        assert_eq "original local commit C is ancestor of merge HEAD" "ancestor" "ancestor"
    else
        assert_eq "original local commit C is ancestor of merge HEAD" "ancestor" "not-ancestor"
    fi

    assert_pass_if_clean "test_non_ff_uses_merge"
}
test_non_ff_uses_merge

# ── Test 2: No rebase-merge/ directory left behind after reconciliation ──────
echo "Test 2: no rebase-merge/ state remains after push reconciliation"
test_no_rebase_state_left() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "prereq: ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fx
    fx=$(_make_non_ff_fixture)
    local tracker="$fx/tracker"
    local git_dir
    git_dir=$(_resolve_git_dir "$tracker")

    (
        source "$TICKET_LIB"
        _push_tickets_branch "$tracker" >/dev/null 2>&1
    )

    if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        assert_eq "no rebase state directory remains" "absent" "present"
    else
        assert_eq "no rebase state directory remains" "absent" "absent"
    fi

    assert_pass_if_clean "test_no_rebase_state_left"
}
test_no_rebase_state_left

# ── Test 3: source code does not use 'git rebase origin/tickets' on the
#            primary reconciliation path (rebase eliminated from default flow) ─
echo "Test 3: _push_tickets_branch does not use 'git rebase' on the primary path"
test_no_rebase_on_primary_path() {
    _snapshot_fail
    # Extract the body of _push_tickets_branch via awk and grep for 'rebase'
    local body
    body=$(awk '/^_push_tickets_branch\(\) \{/,/^\}/' "$TICKET_LIB")
    # shellcheck disable=SC2016
    if echo "$body" | grep -qE '^[[:space:]]*git[[:space:]]+-C[[:space:]]+"\$base_path"[[:space:]]+rebase[[:space:]]+origin/tickets'; then
        assert_eq "_push_tickets_branch uses rebase on primary path" "no" "yes"
    else
        assert_eq "_push_tickets_branch uses rebase on primary path" "no" "no"
    fi
    assert_pass_if_clean "test_no_rebase_on_primary_path"
}
test_no_rebase_on_primary_path

print_summary
