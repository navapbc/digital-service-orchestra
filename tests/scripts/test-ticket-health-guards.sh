#!/usr/bin/env bash
# tests/scripts/test-ticket-health-guards.sh
# RED tests for shared helper functions in plugins/dso/scripts/ticket-lib.sh.
#
# Specifically tests:
#   - ticket_read_status()         — reads compiled ticket status from reducer
#   - ticket_find_open_children()  — lists open child tickets of a given parent
#
# All test functions MUST FAIL until ticket-lib.sh is updated to add these functions.
#
# Usage: bash tests/scripts/test-ticket-health-guards.sh
# Returns: exit non-zero (RED) until ticket-lib.sh implements the helper functions.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-health-guards.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out" | tail -1
}

# ── Helper: create a ticket with a parent and return its ID ───────────────────
_create_child_ticket() {
    local repo="$1"
    local parent_id="$2"
    local title="${3:-Child ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "$title" --parent "$parent_id" 2>/dev/null) || true
    echo "$out" | tail -1
}

# ── Helper: transition a ticket ───────────────────────────────────────────────
_transition_ticket() {
    local repo="$1"
    local ticket_id="$2"
    local from="$3"
    local to="$4"
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" "$from" "$to" 2>/dev/null) || true
}

# ── Test 1: ticket_read_status returns correct compiled status ─────────────────
echo "Test 1: ticket_read_status() function exists and returns current status of a ticket"
test_ticket_read_status_returns_current_status() {
    _snapshot_fail

    # Source ticket-lib.sh to check if ticket_read_status is defined
    # RED: ticket_read_status does not exist in ticket-lib.sh yet
    local fn_exists=0
    (source "$TICKET_LIB" 2>/dev/null && declare -f ticket_read_status >/dev/null 2>&1) || fn_exists=$?

    if [ "$fn_exists" -ne 0 ]; then
        # Function does not exist — assert failure to mark RED
        assert_eq "ticket_read_status function exists in ticket-lib.sh" "exists" "missing"
        assert_pass_if_clean "test_ticket_read_status_returns_current_status"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Create a ticket (status = open by default)
    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Status read test ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for status read test" "non-empty" "empty"
        assert_pass_if_clean "test_ticket_read_status_returns_current_status"
        return
    fi

    # Call ticket_read_status with the tracker_dir and ticket_id
    # Expected: returns "open" since the ticket was just created
    local status_out
    local status_exit=0
    status_out=$(
        (cd "$repo" && source "$TICKET_LIB" && ticket_read_status "$tracker_dir" "$ticket_id")
    ) || status_exit=$?

    # Assert: function exits 0
    assert_eq "ticket_read_status: exits 0" "0" "$status_exit"

    # Assert: returns "open" for a freshly created ticket
    assert_eq "ticket_read_status: returns 'open' for new ticket" "open" "$status_out"

    # Now transition ticket to in_progress and re-check
    _transition_ticket "$repo" "$ticket_id" "open" "in_progress"

    local status_after
    local status_after_exit=0
    status_after=$(
        (cd "$repo" && source "$TICKET_LIB" && ticket_read_status "$tracker_dir" "$ticket_id")
    ) || status_after_exit=$?

    # Assert: returns updated status after transition
    assert_eq "ticket_read_status: returns 'in_progress' after transition" "in_progress" "$status_after"

    assert_pass_if_clean "test_ticket_read_status_returns_current_status"
}
test_ticket_read_status_returns_current_status

# ── Test 2: ticket_find_open_children lists open children of a parent ──────────
echo "Test 2: ticket_find_open_children() function exists and lists open child tickets"
test_ticket_find_open_children_lists_children() {
    _snapshot_fail

    # Source ticket-lib.sh to check if ticket_find_open_children is defined
    # RED: ticket_find_open_children does not exist in ticket-lib.sh yet
    local fn_exists=0
    (source "$TICKET_LIB" 2>/dev/null && declare -f ticket_find_open_children >/dev/null 2>&1) || fn_exists=$?

    if [ "$fn_exists" -ne 0 ]; then
        # Function does not exist — assert failure to mark RED
        assert_eq "ticket_find_open_children function exists in ticket-lib.sh" "exists" "missing"
        assert_pass_if_clean "test_ticket_find_open_children_lists_children"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Create a parent ticket (epic)
    local parent_id
    parent_id=$(_create_ticket "$repo" epic "Parent epic ticket")

    if [ -z "$parent_id" ]; then
        assert_eq "parent ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_ticket_find_open_children_lists_children"
        return
    fi

    # Create two child tickets under the parent
    local child1_id child2_id
    child1_id=$(_create_child_ticket "$repo" "$parent_id" "Child ticket 1")
    child2_id=$(_create_child_ticket "$repo" "$parent_id" "Child ticket 2")

    if [ -z "$child1_id" ] || [ -z "$child2_id" ]; then
        # If child creation with --parent is not yet implemented, the test must
        # still fail RED (children can't be detected if they can't be created).
        assert_eq "child tickets created with parent" "non-empty" "empty: child1=$child1_id child2=$child2_id"
        assert_pass_if_clean "test_ticket_find_open_children_lists_children"
        return
    fi

    # Call ticket_find_open_children: should list both children (both are open)
    local children_out
    local children_exit=0
    children_out=$(
        (cd "$repo" && source "$TICKET_LIB" && ticket_find_open_children "$tracker_dir" "$parent_id")
    ) || children_exit=$?

    # Assert: exits 0
    assert_eq "ticket_find_open_children: exits 0" "0" "$children_exit"

    # Assert: output contains child1_id
    if echo "$children_out" | grep -qF "$child1_id"; then
        assert_eq "ticket_find_open_children: lists child1" "has-child1" "has-child1"
    else
        assert_eq "ticket_find_open_children: lists child1" "has-child1" "missing: $children_out"
    fi

    # Assert: output contains child2_id
    if echo "$children_out" | grep -qF "$child2_id"; then
        assert_eq "ticket_find_open_children: lists child2" "has-child2" "has-child2"
    else
        assert_eq "ticket_find_open_children: lists child2" "has-child2" "missing: $children_out"
    fi

    # Now close child1 and verify it no longer appears in open children
    _transition_ticket "$repo" "$child1_id" "open" "closed"

    local children_after
    local children_after_exit=0
    children_after=$(
        (cd "$repo" && source "$TICKET_LIB" && ticket_find_open_children "$tracker_dir" "$parent_id")
    ) || children_after_exit=$?

    # Assert: closed child1 is NOT in open children list
    if echo "$children_after" | grep -qF "$child1_id"; then
        assert_eq "ticket_find_open_children: excludes closed child1" "excludes-child1" "still-includes-child1"
    else
        assert_eq "ticket_find_open_children: excludes closed child1" "excludes-child1" "excludes-child1"
    fi

    # Assert: open child2 still appears
    if echo "$children_after" | grep -qF "$child2_id"; then
        assert_eq "ticket_find_open_children: still lists open child2" "has-child2" "has-child2"
    else
        assert_eq "ticket_find_open_children: still lists open child2" "has-child2" "missing: $children_after"
    fi

    assert_pass_if_clean "test_ticket_find_open_children_lists_children"
}
test_ticket_find_open_children_lists_children

print_summary
