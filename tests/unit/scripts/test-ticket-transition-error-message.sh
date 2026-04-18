#!/usr/bin/env bash
# tests/unit/scripts/test-ticket-transition-error-message.sh
# TDD RED/GREEN tests for ticket-transition.sh wrong-state error message (4a80-c4a0)
#
# Tests verify that when ticket-transition.sh is invoked with the wrong current_status,
# the error message includes a suggested correct command.
#
# Usage: bash tests/unit/scripts/test-ticket-transition-error-message.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TRANSITION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-transition.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-transition-error-message.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: create a ticket in the given repo and return its ID ───────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out"
}

# ── Fixtures ──────────────────────────────────────────────────────────────────
REPO="$(_make_test_repo)"
TICKET_ID="$(_create_ticket "$REPO")"

echo "Using ticket ID: $TICKET_ID"
echo "Ticket initial state: open (create always starts open)"

# ── Test 1: error message includes suggested command ─────────────────────────
# The ticket is in 'open' state; we pass 'in_progress' as current_status.
# Expected: error on stderr containing "Re-run: ticket transition <id> open closed"
echo ""
echo "--- Test 1: wrong-state error includes suggested command ---"

stderr_output=$(cd "$REPO" && bash "$TRANSITION_SCRIPT" \
    "$TICKET_ID" "in_progress" "closed" 2>&1 >/dev/null || true)

echo "Stderr was: $stderr_output"

assert_contains \
    "error message contains suggested run command" \
    "Re-run: ticket transition $TICKET_ID open closed" \
    "$stderr_output"

# ── Test 2: error message still identifies the actual state ──────────────────
echo ""
echo "--- Test 2: wrong-state error still shows actual and expected states ---"

assert_contains \
    "error message mentions actual status 'open'" \
    '"open"' \
    "$stderr_output"

assert_contains \
    "error message mentions wrong status 'in_progress'" \
    '"in_progress"' \
    "$stderr_output"

# ── Test 3: correct transition succeeds (sanity check) ───────────────────────
echo ""
echo "--- Test 3: correct transition (open -> in_progress) succeeds ---"

transition_exit=0
(cd "$REPO" && bash "$TRANSITION_SCRIPT" "$TICKET_ID" "open" "in_progress" 2>/dev/null) || transition_exit=$?

assert_eq "correct transition exits 0" "0" "$transition_exit"

# ── Test 4: suggested command uses correct target_status ─────────────────────
echo ""
echo "--- Test 4: suggested command includes correct target_status ---"

# Now the ticket is in 'in_progress' after Test 3. Try to close it with wrong current.
# Pass 'open' as current (wrong), 'closed' as target.
stderr_output2=$(cd "$REPO" && bash "$TRANSITION_SCRIPT" \
    "$TICKET_ID" "open" "closed" 2>&1 >/dev/null || true)

echo "Stderr was: $stderr_output2"

assert_contains \
    "suggested command targets correct status 'closed'" \
    "Re-run: ticket transition $TICKET_ID in_progress closed" \
    "$stderr_output2"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
