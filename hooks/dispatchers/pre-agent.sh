#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/pre-agent.sh
# PreToolUse Agent dispatcher: runs worktree-isolation-guard hook function.
#
# Replaces the PreToolUse Agent matcher entry in settings.json:
#   run-hook.sh dispatchers/pre-agent.sh
#
# Hook execution order:
#   1. hook_worktree_isolation_guard — block Agent calls with isolation: "worktree"
#
# Returns: 0 always (the hook uses JSON-based deny, not exit code 2, per claude-code#26923)

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source the dispatcher framework
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all pre-agent hook functions
source "$HOOKS_LIB_DIR/session-misc-functions.sh"

# Source post-functions.sh for hook_tool_logging_pre (non-blocking tool logging)
source "$HOOKS_LIB_DIR/post-functions.sh"

_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_pre_agent_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    # Tool logging runs first (non-blocking, informational only — never returns 2)
    hook_tool_logging_pre "$INPUT" || true

    for _HOOK_FN in \
        hook_worktree_isolation_guard
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
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _pre_agent_dispatch
    exit $?
fi
