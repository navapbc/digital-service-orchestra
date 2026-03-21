#!/usr/bin/env bash
# tests/scripts/test-ticket-show.sh
# Tests for plugins/dso/scripts/ticket-show.sh — `ticket show` subcommand.
#
# Covers:
#   1. ticket show displays compiled state with correct fields
#   2. ticket show fails for unknown/nonexistent ID
#   3. ticket show output is valid JSON
#
# Usage: bash tests/scripts/test-ticket-show.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_SHOW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-show.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-show.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ───────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    # Initialize the ticket system so .tickets-tracker/ is available
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Test 1: ticket show displays compiled state with correct fields ───────────
echo "Test 1: ticket show displays compiled state for a created ticket"
test_ticket_show_displays_compiled_state() {
    # ticket-show.sh must exist
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket first
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Test ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for show test" "non-empty" "empty"
        return
    fi

    # Run ticket show
    local show_output
    local exit_code=0
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "ticket show exits 0" "0" "$exit_code"

    # Assert: output contains correct ticket_type and title
    local field_check
    field_check=$(python3 - "$show_output" <<'PYEOF'
import json, sys

try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

errors = []

if state.get("ticket_type") != "task":
    errors.append(f"ticket_type: expected 'task', got {state.get('ticket_type')!r}")

if state.get("title") != "Test ticket":
    errors.append(f"title: expected 'Test ticket', got {state.get('title')!r}")

if state.get("status") != "open":
    errors.append(f"status: expected 'open', got {state.get('status')!r}")

if errors:
    print("ERRORS:" + "; ".join(errors))
else:
    print("OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "show output has correct ticket_type, title, status" "OK" "OK"
    else
        assert_eq "show output has correct ticket_type, title, status" "OK" "$field_check"
    fi
}
test_ticket_show_displays_compiled_state

# ── Test 2: ticket show fails for unknown ID ─────────────────────────────────
echo "Test 2: ticket show fails for unknown/nonexistent ID"
test_ticket_show_fails_for_unknown_id() {
    # ticket-show.sh must exist
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" show "nonexistent-id" 2>&1 >/dev/null) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "show nonexistent ID exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message contains "not found"
    if echo "$stderr_out" | grep -iq "not found"; then
        assert_eq "error message contains 'not found'" "found" "found"
    else
        assert_eq "error message contains 'not found'" "found" "missing: $stderr_out"
    fi
}
test_ticket_show_fails_for_unknown_id

# ── Test 3: ticket show output is valid JSON ─────────────────────────────────
echo "Test 3: ticket show output is parseable by python3 json.tool"
test_ticket_show_output_is_valid_json() {
    # ticket-show.sh must exist
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "JSON validation ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for JSON validation test" "non-empty" "empty"
        return
    fi

    # Run ticket show and pipe through json.tool
    local parse_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) | python3 -m json.tool >/dev/null 2>/dev/null || parse_exit=$?

    assert_eq "ticket show output is valid JSON" "0" "$parse_exit"
}
test_ticket_show_output_is_valid_json

print_summary
