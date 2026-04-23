#!/usr/bin/env bash
# hooks/dispatchers/pre-exitplanmode.sh
# PreToolUse ExitPlanMode dispatcher: runs plan-review-gate hook function.
#
# Replaces the PreToolUse ExitPlanMode matcher entry in settings.json:
#   run-hook.sh dispatchers/pre-exitplanmode.sh
#
# Hook execution order:
#   1. hook_plan_review_gate — block ExitPlanMode if no plan review recorded
#
# Returns: 0 if allowed, 2 if blocked by plan-review-gate

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source shared ERR handler (fail-open: if missing, continue without trap)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "pre-exitplanmode.sh"
fi

# Source the dispatcher framework
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all pre-exitplanmode hook functions
source "$HOOKS_LIB_DIR/session-misc-functions.sh"

_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_pre_exitplanmode_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    local _fn_exit=0
    _run_hook_fn "hook_plan_review_gate" "$INPUT" || _fn_exit=$?
    if [[ "$_fn_exit" -eq 2 ]]; then
        return 2
    fi

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _pre_exitplanmode_dispatch
    exit $?
fi
