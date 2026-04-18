#!/usr/bin/env bash
# hooks/dispatchers/pre-enterplanmode.sh
# PreToolUse EnterPlanMode dispatcher: runs brainstorm-gate hook function.
#
# Replaces the PreToolUse EnterPlanMode matcher entry in plugin.json:
#   run-hook.sh dispatchers/pre-enterplanmode.sh
#
# Hook execution order:
#   1. hook_brainstorm_gate — block EnterPlanMode if no brainstorm sentinel recorded
#
# Returns: 0 if allowed, 2 if blocked by brainstorm-gate

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source shared ERR handler (fail-open: if missing, continue without trap)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "pre-enterplanmode.sh"
fi

# Source the dispatcher framework
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all pre-enterplanmode hook functions
source "$HOOKS_LIB_DIR/session-misc-functions.sh"

_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_pre_enterplanmode_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    local _fn_exit=0
    _run_hook_fn "hook_brainstorm_gate" "$INPUT" || _fn_exit=$?
    if [[ "$_fn_exit" -eq 2 ]]; then
        return 2
    fi

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _pre_enterplanmode_dispatch
    exit $?
fi
