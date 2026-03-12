#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/pre-bash.sh
# PreToolUse Bash dispatcher: sources all 8 Bash hook functions and runs them
# sequentially. Stops at the first function that returns 2 (block/deny).
#
# Replaces 8 separate settings.json entries with a single dispatcher entry:
#   run-hook.sh dispatchers/pre-bash.sh
#
# Hook execution order (per task spec):
#   1. hook_validation_gate
#   2. hook_commit_failure_tracker
#   3. hook_review_gate
#   4. hook_worktree_bash_guard
#   5. hook_worktree_edit_guard
#   6. hook_bug_close_guard
#   7. hook_tool_use_guard
#   8. hook_review_integrity_guard
#
# Returns: 0 if all hooks allow, 2 if any hook blocks.

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source the dispatcher framework (provides run_hooks — kept for reference/reuse)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all 8 hook functions
source "$HOOKS_LIB_DIR/pre-bash-functions.sh"

# Run all 8 hook functions sequentially.
# Stops at first function that returns 2 (block).
# Non-zero exit codes other than 2 are intentionally allowed to fall through
# (fail-open design): each hook function has its own ERR trap that logs the
# error and returns 0, so a non-2 exit from _run_hook_fn means the hook chose
# to allow. This matches the original per-hook ERR-trap fail-open contract.
# REVIEW-DEFENSE: Fail-open is deliberate — each hook's ERR trap (return 0)
# ensures non-2 exits are safe. Blocking on unknown codes would break the
# fail-open contract and risk false denials on transient errors.
# Only executed when this script is run directly (not sourced), so that
# 'source pre-bash.sh && type hook_validation_gate' works correctly.
_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_pre_bash_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    for _HOOK_FN in \
        hook_validation_gate \
        hook_commit_failure_tracker \
        hook_review_gate \
        hook_worktree_bash_guard \
        hook_worktree_edit_guard \
        hook_bug_close_guard \
        hook_tool_use_guard \
        hook_review_integrity_guard
    do
        local _fn_exit=0
        _run_hook_fn "$_HOOK_FN" "$INPUT" || _fn_exit=$?
        if [[ "$_fn_exit" -eq 2 ]]; then
            return 2
        fi
    done

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
# Detection: BASH_SOURCE[0] == $0 means we were invoked directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _pre_bash_dispatch
    exit $?
fi
