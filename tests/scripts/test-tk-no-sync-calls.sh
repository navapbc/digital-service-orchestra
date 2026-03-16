#!/usr/bin/env bash
# tests/scripts/test-tk-no-sync-calls.sh
#
# Verifies that the tk CLI does not call any cross-worktree sync functions:
#   - _sync_from_main
#   - _sync_ticket_file
#   - _sync_ticket_delete
#   - _sync_diff_changed_tickets
#   - tk-sync-lib (source/load)
#
# TDD: RED phase — this test fails before removing sync calls from tk,
#       GREEN phase — passes after the calls are removed.
#
# Test 1 (behavioral): Create a mock tk-sync-lib.sh that records invocations
#   to a temp file, run `tk start <id>`, assert the mock was never invoked.
#
# Test 2 (regression grep): Grep scripts/tk for sync
#   function names; assert zero matches in non-comment, non-dead-code lines.
#
# Test 3 (smoke): tk ready and tk show <id> exit 0.
#
# Usage: bash tests/scripts/test-tk-no-sync-calls.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
TK_SCRIPT="$PLUGIN_ROOT/scripts/tk"

source "$SCRIPT_DIR/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-tk-no-sync-calls.sh ==="

# ── Shared ticket fixture ────────────────────────────────────────────────────

make_ticket() {
    local dir="$1" id="$2"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: open
title: Ticket ${id}
deps: []
links: []
created: 2026-03-12T00:00:00Z
type: task
priority: 2
---
# Ticket ${id}
EOF
}

# ── Test 1: mock tk-sync-lib.sh — behavioral ─────────────────────────────────
#
# Strategy: put a fake tk-sync-lib.sh ahead of the real one in the same dir
# as tk (using a temp symlinked scripts dir), or more simply: create a temp
# directory with a tk-sync-lib.sh that writes to an invocation log, then run
# tk with TICKETS_DIR pointing at a temp ticket store and PATH that would
# allow the lib to be found via _TK_SCRIPT_DIR.
#
# Simpler approach: source tk with _TK_SOURCE_ONLY=1, then override
# _sync_ticket_file, run the write path, assert it was never called.

echo "Test 1: mock tk-sync-lib.sh — write command must not invoke sync"

TMPDIR_T1=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T1")
INVOCATION_LOG="$TMPDIR_T1/sync-calls.log"
touch "$INVOCATION_LOG"

export TICKETS_DIR="$TMPDIR_T1/tickets"
mkdir -p "$TICKETS_DIR"
make_ticket "$TICKETS_DIR" "ticket-test1"

# Create a mock tk-sync-lib.sh in a temp dir that records invocations
MOCK_SCRIPTS_DIR="$TMPDIR_T1/scripts"
mkdir -p "$MOCK_SCRIPTS_DIR"
cat > "$MOCK_SCRIPTS_DIR/tk-sync-lib.sh" <<MOCK_EOF
# Mock tk-sync-lib.sh — records invocations for test assertions
INVOCATION_LOG="${INVOCATION_LOG}"
_sync_ticket_file() { echo "_sync_ticket_file called with: \$*" >> "\$INVOCATION_LOG"; return 0; }
_sync_ticket_delete() { echo "_sync_ticket_delete called with: \$*" >> "\$INVOCATION_LOG"; return 0; }
_sync_diff_changed_tickets() { echo "_sync_diff_changed_tickets called with: \$*" >> "\$INVOCATION_LOG"; return 0; }
_clear_ticket_skip_worktree() { echo "_clear_ticket_skip_worktree called" >> "\$INVOCATION_LOG"; return 0; }
MOCK_EOF

# Create a wrapper tk script that sets _TK_SCRIPT_DIR to our mock scripts dir
# so the sourcing block finds our mock instead of the real lib.
cat > "$TMPDIR_T1/tk-wrapper.sh" <<WRAPPER_EOF
#!/usr/bin/env bash
# Force _TK_SCRIPT_DIR to the mock scripts dir before sourcing tk.
# We do this by running tk with the environment variable that overrides the dir.
# Since _TK_SCRIPT_DIR is set via \$(dirname BASH_SOURCE[0]) inside tk, we
# can't inject it externally. Instead, we create a symlink to tk in our
# mock scripts dir so BASH_SOURCE[0] resolves there.
exec "${TK_SCRIPT}" "\$@"
WRAPPER_EOF
chmod +x "$TMPDIR_T1/tk-wrapper.sh"

# Create a symlink to tk inside the mock scripts dir so _TK_SCRIPT_DIR is
# the mock scripts dir (which contains our fake tk-sync-lib.sh).
ln -sf "$TK_SCRIPT" "$MOCK_SCRIPTS_DIR/tk"

# Run tk start via the symlinked tk so _TK_SCRIPT_DIR resolves to mock dir
output=$("$MOCK_SCRIPTS_DIR/tk" start ticket-test1 2>&1) || true

sync_call_count=0
if [[ -f "$INVOCATION_LOG" ]]; then
    sync_call_count=$(wc -l < "$INVOCATION_LOG" | tr -d ' ')
fi

if [[ "$sync_call_count" -eq 0 ]]; then
    echo "  PASS: tk start did not invoke any sync functions (invocation log empty)"
    (( PASS++ ))
else
    echo "  FAIL: tk start invoked sync functions ($sync_call_count call(s)):" >&2
    cat "$INVOCATION_LOG" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T1"
unset TICKETS_DIR

# ── Test 2: regression grep — zero sync references in tk ────────────────────

echo "Test 2: grep scripts/tk — no sync function calls"

# Count lines that reference sync functions (excluding comment-only lines).
# The acceptance criteria requires zero matches for these patterns.
sync_grep_count=0
sync_grep_count=$(grep -c '_sync_from_main\|_sync_ticket_file\|_sync_ticket_delete\|_sync_diff_changed_tickets' "$TK_SCRIPT" 2>/dev/null || true)

if [[ "$sync_grep_count" -eq 0 ]]; then
    echo "  PASS: no sync function references found in tk"
    (( PASS++ ))
else
    echo "  FAIL: found $sync_grep_count line(s) with sync function references in tk:" >&2
    grep -n '_sync_from_main\|_sync_ticket_file\|_sync_ticket_delete\|_sync_diff_changed_tickets' "$TK_SCRIPT" >&2 || true
    (( FAIL++ ))
fi

# Also check for tk-sync-lib source
sync_lib_count=0
sync_lib_count=$(grep -c 'tk-sync-lib' "$TK_SCRIPT" 2>/dev/null || true)

if [[ "$sync_lib_count" -eq 0 ]]; then
    echo "  PASS: no tk-sync-lib references found in tk"
    (( PASS++ ))
else
    echo "  FAIL: found $sync_lib_count line(s) with tk-sync-lib reference in tk:" >&2
    grep -n 'tk-sync-lib' "$TK_SCRIPT" >&2 || true
    (( FAIL++ ))
fi

# ── Test 3: smoke — tk ready and tk show exit 0 ──────────────────────────────

echo "Test 3: smoke — tk ready exits 0"

TMPDIR_T3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMPDIR_T3")
export TICKETS_DIR="$TMPDIR_T3"
make_ticket "$TICKETS_DIR" "ticket-smoke1"

ready_exit=0
"$TK_SCRIPT" ready > /dev/null 2>&1 || ready_exit=$?
if [[ "$ready_exit" -eq 0 ]]; then
    echo "  PASS: tk ready exited 0"
    (( PASS++ ))
else
    echo "  FAIL: tk ready exited $ready_exit" >&2
    (( FAIL++ ))
fi

echo "Test 4: smoke — tk show exits 0"
show_exit=0
"$TK_SCRIPT" show ticket-smoke1 > /dev/null 2>&1 || show_exit=$?
if [[ "$show_exit" -eq 0 ]]; then
    echo "  PASS: tk show exited 0"
    (( PASS++ ))
else
    echo "  FAIL: tk show exited $show_exit" >&2
    (( FAIL++ ))
fi

rm -rf "$TMPDIR_T3"
unset TICKETS_DIR

# ── Report ────────────────────────────────────────────────────────────────────

print_results
