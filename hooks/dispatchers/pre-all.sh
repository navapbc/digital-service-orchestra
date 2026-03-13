#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/pre-all.sh
# PreToolUse (empty matcher) dispatcher: handles tool-logging pre-phase.
#
# Replaces the PreToolUse empty-matcher entry in settings.json:
#   run-hook.sh dispatchers/pre-all.sh
#
# Hook execution order:
#   1. tool-logging.sh pre — log tool invocations for session summaries
#
# Returns: 0 always (tool logging is informational; never blocks)

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"
TOOL_LOGGING_HOOK="$CLAUDE_PLUGIN_ROOT/hooks/tool-logging.sh"

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

_pre_all_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

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
                >> /tmp/hook-timing.log 2>/dev/null
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
