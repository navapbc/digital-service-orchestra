#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/pre-write.sh
# PreToolUse Write dispatcher: sources all 4 Write hook functions and runs them
# sequentially. Stops at the first function that returns 2 (block/deny).
#
# Replaces 4 separate settings.json Write PreToolUse entries with a single dispatcher entry:
#   run-hook.sh dispatchers/pre-write.sh
#
# Hook execution order:
#   1. hook_validation_gate         — block sprint/new-work when validation not run
#   2. hook_worktree_edit_guard     — block Write targeting main repo from worktree
#   3. hook_cascade_circuit_breaker — block Write when cascade failure threshold reached
#   4. hook_title_length_validator  — block Write setting ticket titles > 255 chars
#
# Returns: 0 if all hooks allow, 2 if any hook blocks.

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source the dispatcher framework (provides run_hooks — kept for reference/reuse)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all 4 Write hook functions (also sources pre-bash-functions.sh via chain)
source "$HOOKS_LIB_DIR/pre-edit-write-functions.sh"

# Source post-functions.sh for hook_tool_logging_pre (non-blocking tool logging)
source "$HOOKS_LIB_DIR/post-functions.sh"

# Run all 4 hook functions sequentially.
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

_pre_write_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    # Tool logging runs first (non-blocking, informational only — never returns 2)
    hook_tool_logging_pre "$INPUT" || true

    for _HOOK_FN in \
        hook_validation_gate \
        hook_worktree_edit_guard \
        hook_cascade_circuit_breaker \
        hook_title_length_validator
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
    _pre_write_dispatch
    exit $?
fi
