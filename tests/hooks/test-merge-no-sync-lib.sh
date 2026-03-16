#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-merge-no-sync-lib.sh
# TDD tests: verify merge-to-main.sh and worktree-sync-from-main.sh have no
# ticket sync library references after the strip-ticket-logic task.
#
# Tests:
#   test_merge_no_sync_lib_source
#     — grep merge-to-main.sh for tk-sync-lib|_clear_ticket_skip_worktree;
#       assert zero matches.
#   test_merge_no_force_clean_ticket_logic
#     — grep merge-to-main.sh for force.*clean.*ticket|skip.worktree.*ticket;
#       assert zero matches.
#   test_worktree_sync_no_ticket_handling
#     — grep worktree-sync-from-main.sh for tk-sync-lib|_clear_ticket_skip_worktree;
#       assert zero matches.
#
# Usage: bash lockpick-workflow/tests/hooks/test-merge-no-sync-lib.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_SCRIPT="$PLUGIN_ROOT/scripts/merge-to-main.sh"
SYNC_SCRIPT="$PLUGIN_ROOT/scripts/worktree-sync-from-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test 1: merge-to-main.sh has no sync lib references
# =============================================================================
SYNC_LIB_MATCHES=$(grep -c 'tk-sync-lib\|_clear_ticket_skip_worktree' "$MERGE_SCRIPT" 2>/dev/null || true)
assert_eq "test_merge_no_sync_lib_source" "0" "$SYNC_LIB_MATCHES"

# =============================================================================
# Test 2: merge-to-main.sh has no force-clean ticket logic
# =============================================================================
FORCE_CLEAN_MATCHES=$(grep -ciE 'force.*clean.*ticket|skip.worktree.*ticket' "$MERGE_SCRIPT" 2>/dev/null || true)
assert_eq "test_merge_no_force_clean_ticket_logic" "0" "$FORCE_CLEAN_MATCHES"

# =============================================================================
# Test 3: worktree-sync-from-main.sh has no sync lib references
# =============================================================================
SYNC_MATCHES=$(grep -c 'tk-sync-lib\|_clear_ticket_skip_worktree' "$SYNC_SCRIPT" 2>/dev/null || true)
assert_eq "test_worktree_sync_no_ticket_handling" "0" "$SYNC_MATCHES"

# =============================================================================
# Test 4: merge-to-main.sh basic sanity (--help or first line of output)
# =============================================================================
HELP_OUTPUT=$(bash "$MERGE_SCRIPT" --help 2>&1 | head -1 || true)
SYNTAX_OK="false"
if bash -n "$MERGE_SCRIPT" 2>/dev/null; then
    SYNTAX_OK="true"
fi
assert_eq "test_merge_script_syntax_valid" "true" "$SYNTAX_OK"

# =============================================================================
print_summary
