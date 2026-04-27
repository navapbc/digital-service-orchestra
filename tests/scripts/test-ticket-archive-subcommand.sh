#!/usr/bin/env bash
# tests/scripts/test-ticket-archive-subcommand.sh
# RED integration tests for 'ticket archive <id>' subcommand.
#
# Exercises:
#   1. test_archive_open_ticket         — open ticket is archived and excluded from default list
#   2. test_archive_rejects_in_progress — in_progress ticket exits 1 with error message
#   3. test_archive_idempotent          — archiving an already-archived ticket exits 0
#   4. test_archive_show_reflects_archived — ticket show after archive has "archived": true
#
# RED STATE: Tests fail before ticket_archive() + dispatcher case are implemented.
# GREEN STATE: All tests pass after implementation.
#
# Usage: bash tests/scripts/test-ticket-archive-subcommand.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test assertions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$SCRIPT_DIR/../lib/run_test.sh"
source "$SCRIPT_DIR/../lib/git-fixtures.sh"

echo "=== test-ticket-archive-subcommand.sh ==="

# ── Fixture helper ────────────────────────────────────────────────────────────
# Creates a full ticket-ready repo (with ticket system initialized).
_make_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# Creates a ticket and returns its ID (last line of output).
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out" | tail -1
}

# Transitions a ticket to in_progress status.
_set_in_progress() {
    local repo="$1"
    local ticket_id="$2"
    (cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" transition "$ticket_id" open in_progress 2>/dev/null) || true
}

# ── Test 1: archive an open ticket ───────────────────────────────────────────
test_archive_open_ticket() {
    local repo ticket_id list_output list_archived_output exit_code

    repo=$(_make_repo)
    ticket_id=$(_create_ticket "$repo" task "Open ticket to archive")

    if [ -z "$ticket_id" ]; then
        echo "  FAIL: could not create test ticket" >&2
        (( FAIL++ ))
        return
    fi

    # Archive the open ticket
    echo "Test 1a: 'ticket archive <open-id>' exits 0"
    exit_code=0
    (cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" archive "$ticket_id" 2>/dev/null) || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: archive of open ticket exited 0"
        (( PASS++ ))
    else
        echo "  FAIL: archive of open ticket exited $exit_code (expected 0)" >&2
        (( FAIL++ ))
    fi

    # Ticket must NOT appear in default list
    echo "Test 1b: archived ticket excluded from default 'ticket list'"
    list_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" list 2>/dev/null) || true
    if echo "$list_output" | grep -q "\"$ticket_id\""; then
        echo "  FAIL: ticket '$ticket_id' still appears in default list after archive" >&2
        (( FAIL++ ))
    else
        echo "  PASS: archived ticket absent from default list"
        (( PASS++ ))
    fi

    # Ticket MUST appear in --include-archived list
    echo "Test 1c: archived ticket visible with 'ticket list --include-archived'"
    list_archived_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" list --include-archived 2>/dev/null) || true
    if echo "$list_archived_output" | grep -q "\"$ticket_id\""; then
        echo "  PASS: archived ticket visible with --include-archived"
        (( PASS++ ))
    else
        echo "  FAIL: ticket '$ticket_id' not found in --include-archived output" >&2
        (( FAIL++ ))
    fi
}

# ── Test 2: reject non-open statuses ─────────────────────────────────────────
test_archive_rejects_in_progress() {
    local repo ticket_id exit_code err_output

    repo=$(_make_repo)
    ticket_id=$(_create_ticket "$repo" task "In-progress ticket")

    if [ -z "$ticket_id" ]; then
        echo "  FAIL: could not create test ticket" >&2
        (( FAIL++ ))
        return
    fi

    _set_in_progress "$repo" "$ticket_id"

    echo "Test 2: 'ticket archive <in_progress-id>' exits 1 with error message"
    exit_code=0
    err_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" archive "$ticket_id" 2>&1) || exit_code=$?

    if [ "$exit_code" -ne 0 ] && echo "$err_output" | grep -qi "in_progress\|not open\|only.*open\|status"; then
        echo "  PASS: archive rejected in_progress ticket with exit $exit_code and error message"
        (( PASS++ ))
    elif [ "$exit_code" -ne 0 ]; then
        echo "  FAIL: archive exited $exit_code but error message missing status context" >&2
        echo "  Output: $err_output" >&2
        (( FAIL++ ))
    else
        echo "  FAIL: archive of in_progress ticket should have exited non-zero (got 0)" >&2
        (( FAIL++ ))
    fi
}

# ── Test 3: idempotent — second archive exits 0 silently ─────────────────────
test_archive_idempotent() {
    local repo ticket_id exit_code1 exit_code2

    repo=$(_make_repo)
    ticket_id=$(_create_ticket "$repo" task "Ticket for idempotent test")

    if [ -z "$ticket_id" ]; then
        echo "  FAIL: could not create test ticket" >&2
        (( FAIL++ ))
        return
    fi

    echo "Test 3a: first archive exits 0"
    exit_code1=0
    (cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" archive "$ticket_id" 2>/dev/null) || exit_code1=$?
    if [ "$exit_code1" -eq 0 ]; then
        echo "  PASS: first archive exited 0"
        (( PASS++ ))
    else
        echo "  FAIL: first archive exited $exit_code1 (expected 0)" >&2
        (( FAIL++ ))
    fi

    echo "Test 3b: second archive (already archived) exits 0 (idempotent)"
    exit_code2=0
    (cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" archive "$ticket_id" 2>/dev/null) || exit_code2=$?
    if [ "$exit_code2" -eq 0 ]; then
        echo "  PASS: second archive exited 0 (idempotent)"
        (( PASS++ ))
    else
        echo "  FAIL: second archive exited $exit_code2 (expected 0 — idempotent)" >&2
        (( FAIL++ ))
    fi
}

# ── Test 4: ticket show reflects archived: true ───────────────────────────────
test_archive_show_reflects_archived() {
    local repo ticket_id show_output archived_val exit_code

    repo=$(_make_repo)
    ticket_id=$(_create_ticket "$repo" task "Ticket to check show after archive")

    if [ -z "$ticket_id" ]; then
        echo "  FAIL: could not create test ticket" >&2
        (( FAIL++ ))
        return
    fi

    echo "Test 4: 'ticket show <id>' after archive has \"archived\": true"
    exit_code=0
    (cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" archive "$ticket_id" 2>/dev/null) || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "  FAIL: archive of open ticket exited $exit_code (expected 0)" >&2
        (( FAIL++ ))
        return
    fi

    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$DISPATCHER" show "$ticket_id" 2>/dev/null) || true
    archived_val=$(echo "$show_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('archived','MISSING'))" 2>/dev/null) || archived_val="ERROR"

    if [ "$archived_val" = "True" ] || [ "$archived_val" = "true" ]; then
        echo "  PASS: ticket show reports archived=true after archive"
        (( PASS++ ))
    else
        echo "  FAIL: ticket show 'archived' field is '$archived_val' (expected true)" >&2
        echo "  Full show output: $show_output" >&2
        (( FAIL++ ))
    fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_archive_open_ticket
test_archive_rejects_in_progress
test_archive_idempotent
test_archive_show_reflects_archived

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
