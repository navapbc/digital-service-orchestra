#!/usr/bin/env bash
# hooks/dispatchers/stop.sh
# Stop dispatcher: sources all Stop hook functions and runs them sequentially.
#
# Replaces 2 separate settings.json Stop entries with a single dispatcher:
#   run-hook.sh dispatchers/stop.sh
#
# Hook execution order:
#   1. hook_review_stop_check          — warn about uncommitted unreviewed changes
#   2. hook_tool_logging_summary       — emit session tool usage summary
#   3. hook_friction_suggestion_check  — record friction suggestion from tool logs
#
# Returns: 0 always (Stop hooks are informational; they output warnings but never block)

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# DEFENSE-IN-DEPTH: fail-open — never block or surface errors.
exec 2>/dev/null
trap 'exit 0' EXIT

# Source the dispatcher framework
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all stop hook functions
source "$HOOKS_LIB_DIR/session-misc-functions.sh"

_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_stop_dispatch() {
    # Stop hooks do NOT receive stdin JSON — pass empty input
    local INPUT="{}"

    for _HOOK_FN in \
        hook_review_stop_check \
        hook_tool_logging_summary \
        hook_friction_suggestion_check
    do
        local _fn_exit=0
        _run_hook_fn "$_HOOK_FN" "$INPUT" || _fn_exit=$?
        # Stop hooks are all informational — never block
    done

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _stop_dispatch
    exit $?
fi
