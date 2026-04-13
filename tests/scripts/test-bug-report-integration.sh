#!/usr/bin/env bash
# tests/scripts/test-bug-report-integration.sh
# Integration and actionable-remediation tests for bug report CLI validation.
#
# Covers:
#   SC 12 — Integration: non-conforming bug ticket emits warnings to stderr,
#           exits 0, and persists the ticket.
#   SC 14 — Actionable remediation: warning text includes ticket edit command,
#           missing header names, and bug report template path.
#
# Usage: bash tests/scripts/test-bug-report-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_CREATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-create.sh"
TICKET_SHOW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-show.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-bug-report-integration.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ───────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── SC 12: Integration test — warnings, exit 0, ticket persisted ─────────────
echo ""
echo "SC 12: Integration — non-conforming bug emits warnings, exits 0, persists ticket"
test_integration_warnings_exit_persistence() {
    local repo
    repo=$(_make_test_repo)

    local stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")

    # Create a bug with non-conforming title AND description missing required headers
    local ticket_id exit_code
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "bad title no pattern" -d "Some description without headers" 2>"$stderr_out")
    exit_code=$?

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # Assert: exit code is 0
    assert_eq "exit code is 0" "0" "$exit_code"

    # Assert: ticket ID is non-empty
    assert_ne "ticket ID is non-empty" "" "$ticket_id"

    # Assert: stderr contains title pattern warning
    assert_contains "stderr has title pattern warning" "Bug title does not match" "$stderr_content"

    # Assert: stderr contains description headers warning
    assert_contains "stderr has description headers warning" "missing recommended headers" "$stderr_content"

    # Assert: ticket is persisted — ticket show returns the ticket
    local show_output show_exit
    show_output=$(cd "$repo" && bash "$TICKET_SHOW_SCRIPT" "$ticket_id" 2>/dev/null)
    show_exit=$?
    assert_eq "ticket show exits 0" "0" "$show_exit"
    assert_contains "ticket show returns ticket ID" "$ticket_id" "$show_output"
}
test_integration_warnings_exit_persistence

# ── SC 14: Actionable remediation test — warning includes edit cmd, headers, template ─
echo ""
echo "SC 14: Actionable remediation — warning includes edit command, header names, template path"
test_actionable_remediation_warnings() {
    local repo
    repo=$(_make_test_repo)

    local stderr_out
    stderr_out=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_out")

    # Create a bug without required headers to trigger description warning
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_CREATE_SCRIPT" bug "bad title no pattern" -d "No headers here" 2>"$stderr_out")

    local stderr_content
    stderr_content=$(cat "$stderr_out")

    # (a) Warning includes ticket edit command syntax
    assert_contains "warning includes 'ticket edit' command" "ticket edit" "$stderr_content"

    # (b) Warning includes the specific missing header names
    assert_contains "warning includes 'Expected Behavior'" "Expected Behavior" "$stderr_content"
    assert_contains "warning includes 'Actual Behavior'" "Actual Behavior" "$stderr_content"

    # (c) Warning includes the path to the bug report template
    assert_contains "warning includes template path" "plugins/dso/skills/shared/prompts/bug-report-template.md" "$stderr_content"
}
test_actionable_remediation_warnings

print_summary
