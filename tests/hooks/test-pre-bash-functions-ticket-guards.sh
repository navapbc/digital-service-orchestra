#!/usr/bin/env bash
# tests/hooks/test-pre-bash-functions-ticket-guards.sh
# TDD RED tests for ticket-based guard command detection.
#
# These tests assert the POST-MIGRATION state:
#   - hook_bug_close_guard should fire on "ticket transition" commands
#     (currently only fires on "tk close" commands — RED)
#   - closed-parent-guard.sh should fire on "ticket create --parent"
#     (currently only fires on "tk create --parent" — RED)
#
# GREEN tests (pass before and after migration):
#   test_bug_close_guard_no_false_positive_on_ticket_show
#   test_closed_parent_guard_does_not_fire_on_tk_sync
#
# RED tests (fail before migration; pass after dso-yv90 implements the changes):
#   test_bug_close_guard_fires_on_ticket_transition_closed
#   test_closed_parent_guard_fires_on_ticket_create_parent
#
# RED marker: test_bug_close_guard_fires_on_ticket_transition_closed
# (all tests at and after this marker are expected to fail until dso-yv90)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

PRE_BASH_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"
CLOSED_PARENT_GUARD="$DSO_PLUGIN_DIR/hooks/closed-parent-guard.sh"

# Source pre-bash-functions to get hook_bug_close_guard and parse_json_field
# shellcheck source=/dev/null
source "$PRE_BASH_FUNCTIONS"

# Temp directory for fake git repo and ticket files
_FAKE_REPO=$(mktemp -d)
trap 'rm -rf "$_FAKE_REPO"' EXIT

# Initialize a minimal git repo so git rev-parse --show-toplevel resolves correctly
(
    cd "$_FAKE_REPO"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -q -m "init"
)

# Create a fake bug ticket at .tickets/ (pre-migration lookup path)
mkdir -p "$_FAKE_REPO/.tickets"
cat > "$_FAKE_REPO/.tickets/abc1-def2.md" << 'TICKET_EOF'
---
id: abc1-def2
type: bug
status: open
---
# Bug: test bug ticket
TICKET_EOF

# Helper: run hook_bug_close_guard inside _FAKE_REPO so git resolves to it
_run_bug_close_guard() {
    local input="$1"
    local exit_code=0
    (
        cd "$_FAKE_REPO"
        # Re-source pre-bash-functions in the subshell so all helpers are available
        # shellcheck source=/dev/null
        source "$PRE_BASH_FUNCTIONS"
        hook_bug_close_guard "$input" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# =============================================================================
# GREEN tests — expected to pass with both pre- and post-migration code
# =============================================================================

# ============================================================
# test_bug_close_guard_no_false_positive_on_ticket_show
# hook_bug_close_guard must NOT block (exit 0) on non-close commands.
# "ticket show" is a read-only command and must pass through.
# ============================================================
test_bug_close_guard_no_false_positive_on_ticket_show() {
    local input exit_code
    input='{"tool_name":"Bash","tool_input":{"command":"ticket show abc1-def2"}}'
    exit_code=$(_run_bug_close_guard "$input")
    assert_eq "test_bug_close_guard_no_false_positive_on_ticket_show" "0" "$exit_code"
}

# ============================================================
# test_closed_parent_guard_does_not_fire_on_tk_sync
# closed-parent-guard.sh must NOT block (exit 0) on commands that
# don't match the create/dep patterns.
# "tk sync" must still pass through — it's a valid operation.
# ============================================================
test_closed_parent_guard_does_not_fire_on_tk_sync() {
    local exit_code=0
    (
        cd "$_FAKE_REPO"
        echo '{"tool_name":"Bash","tool_input":{"command":"tk sync"}}' \
            | bash "$CLOSED_PARENT_GUARD" 2>/dev/null
    ) || exit_code=$?
    assert_eq "test_closed_parent_guard_does_not_fire_on_tk_sync" "0" "$exit_code"
}

# =============================================================================
# RED tests — expected to FAIL before dso-yv90 implements the changes.
# These tests must be placed at the end of the file (RED marker boundary).
# =============================================================================

# ============================================================
# test_bug_close_guard_fires_on_ticket_transition_closed
# hook_bug_close_guard must block (exit 2) when a bug ticket is closed
# via the new "ticket transition <id> <from> closed" syntax.
# POST-MIGRATION: guard should detect "ticket transition ... closed"
# ============================================================
test_bug_close_guard_fires_on_ticket_transition_closed() {
    local input exit_code
    input='{"tool_name":"Bash","tool_input":{"command":"ticket transition abc1-def2 open closed --reason=fixed"}}'
    exit_code=$(_run_bug_close_guard "$input")
    assert_eq "test_bug_close_guard_fires_on_ticket_transition_closed" "2" "$exit_code"
}

# ============================================================
# test_closed_parent_guard_fires_on_ticket_create_parent
# closed-parent-guard.sh must block (exit 2) when:
#   ticket create "title" --parent <id>
# where the parent ticket is closed.
# POST-MIGRATION: guard should detect "ticket create ... --parent"
# ============================================================
test_closed_parent_guard_fires_on_ticket_create_parent() {
    # Write a closed parent ticket
    cat > "$_FAKE_REPO/.tickets/abc1-def2.md" << 'CLOSED_EOF'
---
id: abc1-def2
type: story
status: closed
---
# Story: closed parent ticket
CLOSED_EOF

    local exit_code=0
    (
        cd "$_FAKE_REPO"
        echo '{"tool_name":"Bash","tool_input":{"command":"ticket create \"new story\" --parent abc1-def2"}}' \
            | bash "$CLOSED_PARENT_GUARD" 2>/dev/null
    ) || exit_code=$?
    assert_eq "test_closed_parent_guard_fires_on_ticket_create_parent" "2" "$exit_code"
}

# Run GREEN tests first, then RED tests
test_bug_close_guard_no_false_positive_on_ticket_show
test_closed_parent_guard_does_not_fire_on_tk_sync
test_bug_close_guard_fires_on_ticket_transition_closed
test_closed_parent_guard_fires_on_ticket_create_parent

print_summary
