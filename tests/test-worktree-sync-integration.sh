#!/usr/bin/env bash
# lockpick-workflow/tests/test-worktree-sync-integration.sh
# Integration tests verifying the worktree-sync-from-main.sh source chain:
#   1. merge-to-main.sh sources wrapper -> wrapper sources canonical -> _worktree_sync_from_main available
#   2. Direct execution delegates to plugin copy (exec mode)
#   3. _clear_ticket_skip_worktree available transitively via tk-sync-lib.sh
#
# Tests:
#   test_source_chain_provides_worktree_sync_function
#   test_clear_ticket_skip_worktree_transitively_available
#   test_wrapper_exec_mode_delegates

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ============================================================
# (1) test_source_chain_provides_worktree_sync_function
#
# When the wrapper scripts/worktree-sync-from-main.sh is sourced,
# the _worktree_sync_from_main function must be available. This is
# the chain merge-to-main.sh relies on.
# ============================================================

echo "--- test_source_chain_provides_worktree_sync_function ---"

# Source the wrapper in a subshell and check for the function
FUNC_TYPE=$(bash -c "source '$REPO_ROOT/scripts/worktree-sync-from-main.sh' && type -t _worktree_sync_from_main" 2>/dev/null || echo "not_found")

assert_eq "wrapper source-mode provides _worktree_sync_from_main" "function" "$FUNC_TYPE"

# ============================================================
# (2) test_clear_ticket_skip_worktree_transitively_available
#
# When the wrapper is sourced, _clear_ticket_skip_worktree must
# also be available (loaded transitively via canonical ->
# tk-sync-lib.sh).
# ============================================================

echo "--- test_clear_ticket_skip_worktree_transitively_available ---"

CLEAR_TYPE=$(bash -c "source '$REPO_ROOT/scripts/worktree-sync-from-main.sh' && type -t _clear_ticket_skip_worktree" 2>/dev/null || echo "not_found")

assert_eq "wrapper source-mode provides _clear_ticket_skip_worktree transitively" "function" "$CLEAR_TYPE"

# ============================================================
# (3) test_wrapper_exec_mode_delegates
#
# When the wrapper is executed directly (not sourced), it must
# delegate to the canonical plugin copy via exec. We verify this
# by checking that the wrapper contains the exec delegation pattern
# and that the canonical target exists and is executable.
# ============================================================

echo "--- test_wrapper_exec_mode_delegates ---"

WRAPPER="$REPO_ROOT/scripts/worktree-sync-from-main.sh"
CANONICAL="$REPO_ROOT/lockpick-workflow/scripts/worktree-sync-from-main.sh"

# Wrapper must contain exec delegation
assert_eq "wrapper contains exec delegation" "true" \
    "$(grep -q 'exec.*\$_WSYNC_CANONICAL' "$WRAPPER" && echo true || echo false)"

# Canonical target must exist
assert_eq "canonical script exists" "true" \
    "$(test -f "$CANONICAL" && echo true || echo false)"

# Canonical target must be executable
assert_eq "canonical script is executable" "true" \
    "$(test -x "$CANONICAL" && echo true || echo false)"

# Wrapper must also contain source delegation for source-mode
assert_eq "wrapper contains source delegation" "true" \
    "$(grep -q 'source.*\$_WSYNC_CANONICAL' "$WRAPPER" && echo true || echo false)"

# ============================================================
# Summary
# ============================================================

print_summary
