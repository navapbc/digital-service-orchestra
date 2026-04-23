#!/usr/bin/env bash
# hooks/dispatchers/pre-all.sh
# PreToolUse (empty matcher) dispatcher: handles tool-logging pre-phase.
#
# Replaces the PreToolUse empty-matcher entry in settings.json:
#   run-hook.sh dispatchers/pre-all.sh
#
# Hook execution order:
#   1. hook_checkpoint_rollback — unwind pre-compact checkpoint if marker present
#   2. tool-logging.sh pre — log tool invocations for session summaries
#
# Returns: 0 always (checkpoint rollback and tool logging are informational; never blocks)
#
# NOTE: This dispatcher is no longer registered as an empty-matcher in settings.json.
# It was removed to reduce process count per tool call (N+1 → N).
# Tool logging is unavailable for tools without dedicated dispatchers
# (Read, Glob, Grep, Skill, ToolSearch) — accepted tradeoff for process count reduction.
# Tool logging remains available for Bash, Edit, and Write via their dedicated dispatchers.

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"
TOOL_LOGGING_HOOK="$CLAUDE_PLUGIN_ROOT/hooks/tool-logging.sh"

# Source shared ERR handler (fail-open: if missing, continue without trap)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "pre-all.sh"
fi

# Source the dispatcher framework
source "$HOOKS_LIB_DIR/dispatcher.sh"

# macOS-compatible millisecond timestamp (date +%s%N unavailable on macOS)
_get_ms() {
    local _ns
    _ns=$(date +%s%N 2>/dev/null) || _ns=""
    if [[ -n "$_ns" && "$_ns" != *N* ]]; then
        echo $(( _ns / 1000000 ))
    else
        python3 -c 'import time;print(int(time.time()*1e3))' 2>/dev/null || echo 0
    fi
}

# Source pre-all function library (for checkpoint rollback)
source "$HOOKS_LIB_DIR/pre-all-functions.sh"

_pre_all_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    # 1. Checkpoint rollback (before any other hooks)
    hook_checkpoint_rollback "$INPUT"

    # Fast-path: skip tool-logging subprocess entirely when logging is disabled
    # (avoids ~10-50ms subprocess overhead per tool call)
    test -f "$HOME/.claude/tool-logging-enabled" || return 0

    # Run tool-logging pre phase (informational, never blocks)
    if [[ -x "$TOOL_LOGGING_HOOK" ]]; then
        local _exit=0
        # Per-call timing (enabled by ~/.claude/hook-timing-enabled)
        if [[ -f "$HOME/.claude/hook-timing-enabled" ]]; then
            local _start _end
            _start=$(_get_ms)
            echo "$INPUT" | bash "$TOOL_LOGGING_HOOK" pre 2>/dev/null || _exit=$?
            _end=$(_get_ms)
            printf '%s\ttool-logging-pre\t%dms\texit=%d\n' \
                "$(date +%H:%M:%S)" "$((_end - _start))" "$_exit" \
                >> "${HOOK_TIMING_LOG:-/tmp/hook-timing.log}" 2>/dev/null
        else
            echo "$INPUT" | bash "$TOOL_LOGGING_HOOK" pre 2>/dev/null || _exit=$?
        fi
        # Non-blocking: ignore exit codes
    fi

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _pre_all_dispatch
    exit $?
fi
