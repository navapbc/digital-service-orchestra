#!/usr/bin/env bash
# hooks/dispatchers/pre-edit.sh
# PreToolUse Edit dispatcher: sources all 5 Edit hook functions and runs them
# sequentially. Stops at the first function that returns 2 (block/deny).
#
# Replaces 4 separate settings.json Edit PreToolUse entries with a single dispatcher entry:
#   run-hook.sh dispatchers/pre-edit.sh
#
# Hook execution order:
#   1. hook_worktree_edit_guard     — block Edit targeting main repo from worktree
#   2. hook_cascade_circuit_breaker — block Edit when cascade failure threshold reached
#   3. hook_title_length_validator  — block Edit setting ticket titles > 255 chars
#   4. hook_tickets_tracker_guard   — block Edit targeting .tickets-tracker/ files
#   5. hook_block_generated_reviewer_agents — block Edit to generated code-reviewer-*.md files
#
# Returns: 0 if all hooks allow, 2 if any hook blocks.

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source shared ERR handler (fail-open: if missing, continue without trap)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "pre-edit.sh"
fi

# Source the dispatcher framework (provides run_hooks — kept for reference/reuse)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all 5 Edit hook functions (also sources pre-bash-functions.sh via chain)
source "$HOOKS_LIB_DIR/pre-edit-write-functions.sh"

# Run all 5 hook functions sequentially.
# Stops at first function that returns 2 (block).
# Non-zero exit codes other than 2 are intentionally allowed to fall through
# (fail-open design): each hook function has its own ERR trap that logs the
# error and returns 0, so a non-2 exit from _run_hook_fn means the hook chose
# to allow.
_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_pre_edit_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    for _HOOK_FN in \
        hook_worktree_edit_guard \
        hook_cascade_circuit_breaker \
        hook_title_length_validator \
        hook_tickets_tracker_guard \
        hook_block_generated_reviewer_agents
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
    _pre_edit_dispatch
    exit $?
fi
