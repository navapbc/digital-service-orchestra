#!/usr/bin/env bash
# tests/acceptance/test-ticket-delete-e2e.sh
# E2E acceptance tests for the full ticket delete lifecycle.
#
# GREEN tests — these must PASS because ticket delete is already implemented.
# Covers: --user-approved guard, children-block deletion, list visibility,
# --include-archived visibility, ready_to_work unblocking after delete, and
# transitioning a deleted ticket exits non-zero.
#
# Usage: bash tests/acceptance/test-ticket-delete-e2e.sh

# NOTE: -e is intentionally omitted — assertion helpers and early-return guards
# use non-zero returns by design. -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-delete-e2e.sh ==="

# ── Cleanup array (git-fixtures.sh may already have set _CLEANUP_DIRS) ────────
# git-fixtures.sh registers its own EXIT trap when it sets _CLEANUP_DIRS.
# We just append to it; no need for a duplicate trap here.

# ── Helper: create a fresh ticket-enabled repo ────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local extra_args="${4:-}"
    local out
    # shellcheck disable=SC2086
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" $extra_args 2>/dev/null) || true
    echo "$out" | tail -1
}

# ── Helper: extract a JSON field from `ticket deps` output ───────────────────
_deps_field() {
    local repo="$1"
    local ticket_id="$2"
    local field="$3"
    local output
    output=$(cd "$repo" && bash "$TICKET_SCRIPT" deps "$ticket_id" 2>/dev/null) || output=""
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    val = d.get(sys.argv[2])
    print(str(val).lower() if isinstance(val, bool) else (str(val) if val is not None else ''))
except Exception:
    print('')
" "$output" "$field" 2>/dev/null || true
}

# ── Helper: extract status from `ticket show` output ─────────────────────────
_show_status() {
    local repo="$1"
    local ticket_id="$2"
    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || show_output=""
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get('status', ''))
except Exception:
    print('')
" "$show_output" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Full lifecycle — delete clears blocker and sets status:deleted
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-1: full lifecycle (blocker delete → ready_to_work, status:deleted, not in list)"
test_full_delete_lifecycle() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create ticket A (the one to delete) and ticket D (blocked by A)
    local tkt_a tkt_d
    tkt_a=$(_create_ticket "$repo" task "Task to delete")
    tkt_d=$(_create_ticket "$repo" task "Task blocked by A")

    if [ -z "$tkt_a" ] || [ -z "$tkt_d" ]; then
        assert_eq "both tickets A and D created" "non-empty" "empty"
        assert_pass_if_clean "test_full_delete_lifecycle"
        return
    fi

    # Link A blocks D
    local link_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" link "$tkt_a" "$tkt_d" blocks >/dev/null 2>&1) || link_exit=$?
    assert_eq "link A blocks D exits 0" "0" "$link_exit"

    # D should NOT be ready_to_work before delete (A is an open blocker)
    local rtw_before
    rtw_before=$(_deps_field "$repo" "$tkt_d" "ready_to_work")
    assert_eq "D not ready_to_work before delete (A is open blocker)" "false" "$rtw_before"

    # Delete A with --user-approved
    local delete_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" delete "$tkt_a" --user-approved >/dev/null 2>&1) || delete_exit=$?
    assert_eq "delete A exits 0" "0" "$delete_exit"

    # ticket show A should return status:deleted
    local status_val
    status_val=$(_show_status "$repo" "$tkt_a")
    assert_eq "ticket show returns status:deleted" "deleted" "$status_val"

    # ticket list should NOT include A (deleted tickets are excluded by default)
    local list_after
    list_after=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || list_after=""
    local still_present=0
    [[ "$list_after" == *"$tkt_a"* ]] && still_present=1
    assert_eq "deleted ticket absent from ticket list" "0" "$still_present"

    # D should now be ready_to_work=true (blocker A was deleted)
    local rtw_after
    rtw_after=$(_deps_field "$repo" "$tkt_d" "ready_to_work")
    assert_eq "D ready_to_work=true after blocker deleted" "true" "$rtw_after"

    # Transitioning a deleted ticket should fail (deleted is terminal)
    local transition_exit=0
    local transition_out
    transition_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$tkt_a" deleted closed 2>&1) || transition_exit=$?
    assert_ne "transition deleted→closed exits non-zero" "0" "$transition_exit"

    assert_pass_if_clean "test_full_delete_lifecycle"
}
test_full_delete_lifecycle

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Children block deletion
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-2: children block deletion"
test_children_block_deletion() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create parent epic and child story
    local parent_id child_id
    parent_id=$(_create_ticket "$repo" epic "Epic with children")

    if [ -z "$parent_id" ]; then
        assert_eq "parent epic created" "non-empty" "empty"
        assert_pass_if_clean "test_children_block_deletion"
        return
    fi

    child_id=$(_create_ticket "$repo" story "Child story" "--parent $parent_id")

    if [ -z "$child_id" ]; then
        assert_eq "child story created" "non-empty" "empty"
        assert_pass_if_clean "test_children_block_deletion"
        return
    fi

    # Attempt to delete the parent — should be blocked
    local exit_code=0
    local combined_output
    combined_output=$(cd "$repo" && bash "$TICKET_SCRIPT" delete "$parent_id" --user-approved 2>&1) || exit_code=$?

    assert_ne "delete with children exits non-zero" "0" "$exit_code"
    assert_contains "output contains child ticket ID" "$child_id" "$combined_output"

    assert_pass_if_clean "test_children_block_deletion"
}
test_children_block_deletion

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Delete without --user-approved is rejected
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-3: delete without --user-approved exits non-zero with usage hint"
test_delete_requires_user_approved() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Guard flag test")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for guard flag test" "non-empty" "empty"
        assert_pass_if_clean "test_delete_requires_user_approved"
        return
    fi

    local exit_code=0
    local combined_output
    combined_output=$(cd "$repo" && bash "$TICKET_SCRIPT" delete "$ticket_id" 2>&1) || exit_code=$?

    assert_ne "delete without --user-approved exits non-zero" "0" "$exit_code"
    assert_contains "output mentions --user-approved" "--user-approved" "$combined_output"

    assert_pass_if_clean "test_delete_requires_user_approved"
}
test_delete_requires_user_approved

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Deleted ticket absent from list; present with --include-archived
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-4: deleted ticket absent from list, present with --include-archived"
test_delete_list_visibility() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Ticket for visibility test")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for visibility test" "non-empty" "empty"
        assert_pass_if_clean "test_delete_list_visibility"
        return
    fi

    # Confirm it's visible before deletion
    local list_before
    list_before=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || list_before=""
    assert_contains "ticket visible before delete" "$ticket_id" "$list_before"

    # Delete the ticket
    local delete_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" delete "$ticket_id" --user-approved >/dev/null 2>&1) || delete_exit=$?
    assert_eq "delete exits 0" "0" "$delete_exit"

    # Should NOT appear in default list
    local list_after
    list_after=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || list_after=""
    local present_default=0
    [[ "$list_after" == *"$ticket_id"* ]] && present_default=1
    assert_eq "deleted ticket absent from default list" "0" "$present_default"

    # SHOULD appear in --include-archived list
    local list_archived
    list_archived=$(cd "$repo" && bash "$TICKET_SCRIPT" list --include-archived 2>/dev/null) || list_archived=""
    assert_contains "deleted ticket present in --include-archived list" "$ticket_id" "$list_archived"

    assert_pass_if_clean "test_delete_list_visibility"
}
test_delete_list_visibility

print_summary
