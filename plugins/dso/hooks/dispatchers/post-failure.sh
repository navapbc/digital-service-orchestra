#!/usr/bin/env bash
# hooks/dispatchers/post-failure.sh
# PostToolUseFailure dispatcher: sources all post-failure hook functions and runs them.
#
# Replaces 1 separate settings.json PostToolUseFailure entry with a single dispatcher:
#   run-hook.sh dispatchers/post-failure.sh
#
# Hook execution order:
#   1. hook_exit_144_forensic_logger — log forensic data on exit 144 (SIGURG timeout/cancellation)
#   2. hook_track_tool_errors — track, categorize, and count tool use errors
#
# Returns: 0 always (non-blocking; tracks errors and emits warnings only)

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source shared ERR handler (fail-open: if missing, keep original silent trap behavior)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "post-failure.sh"
else
    trap 'exit 0' ERR
fi

# DEFENSE-IN-DEPTH: Guarantee exit 0, suppress stderr, and always produce output.
# Claude Code bug #10463: 0-byte stdout is treated as "hook error" even with exit 0.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
exec 2>/dev/null

# Source the dispatcher framework
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all post-failure hook functions
source "$HOOKS_LIB_DIR/session-misc-functions.sh"
source "$HOOKS_LIB_DIR/post-functions.sh"

_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_post_failure_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    for _HOOK_FN in \
        hook_exit_144_forensic_logger \
        hook_track_tool_errors
    do
        local _fn_exit=0
        _run_hook_fn "$_HOOK_FN" "$INPUT" || _fn_exit=$?
        # PostToolUseFailure hooks are non-blocking
    done

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_failure_dispatch
    exit $?
fi
