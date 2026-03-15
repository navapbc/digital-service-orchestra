#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/post-all.sh
# PostToolUse catch-all dispatcher: timing instrumentation for all tools.
# No blocking post-hooks. Kept for timing support.
#
# PostToolUse hooks always exit 0 (non-blocking).
# Always emits at least '{}' on stdout per Claude Code bug #10463 workaround.

# DEFENSE-IN-DEPTH: Guarantee exit 0 and non-empty stdout on any unexpected failure.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

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

# Source the dispatcher framework (provides run_hooks)
source "$HOOKS_LIB_DIR/dispatcher.sh"

_post_all_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    # Per-call timing (enabled by ~/.claude/hook-timing-enabled)
    if [[ -f "$HOME/.claude/hook-timing-enabled" ]]; then
        local _end
        _end=$(_get_ms)
        local _tool_name
        _tool_name=$(parse_json_field "$INPUT" '.tool_name' 2>/dev/null || echo "unknown")
        printf '%s\tpost-all\t%s\t%s\n' \
            "$(date +%H:%M:%S)" "$_tool_name" "${_end}ms" \
            >> "${HOOK_TIMING_LOG:-/tmp/hook-timing.log}" 2>/dev/null
    fi
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_all_dispatch
    exit 0
fi
