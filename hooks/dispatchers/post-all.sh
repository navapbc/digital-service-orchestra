#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/post-all.sh
# PostToolUse catch-all dispatcher: sources the 1 all-tools post-hook function and runs it.
#
# Replaces the empty-matcher settings.json entry with a single dispatcher entry:
#   run-hook.sh dispatchers/post-all.sh
#
# Hook execution order:
#   1. hook_tool_logging_post
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

# Source the dispatcher framework (provides run_hooks)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all post hook functions
source "$HOOKS_LIB_DIR/post-functions.sh"

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

# Run all catch-all post-hook functions sequentially.
# PostToolUse hooks are non-blocking (always return 0).
_run_post_fn() {
    local fn_name="$1"
    local json_input="$2"
    local _fn_out=""

    # Per-function timing (enabled by ~/.claude/hook-timing-enabled)
    if [[ -f "$HOME/.claude/hook-timing-enabled" ]]; then
        local _start _end _exit=0
        _start=$(_get_ms)
        _fn_out=$("$fn_name" "$json_input" 2>/dev/null) || _exit=$?
        _end=$(_get_ms)
        printf '%s\t%s\t%dms\texit=%d\n' \
            "$(date +%H:%M:%S)" "$fn_name" "$((_end - _start))" "$_exit" \
            >> /tmp/hook-timing.log 2>/dev/null
    else
        _fn_out=$("$fn_name" "$json_input" 2>/dev/null) || true
    fi

    if [[ -n "$_fn_out" ]] && [[ "$_fn_out" != "{}" ]]; then
        _HOOK_HAS_OUTPUT=1
        printf '%s\n' "$_fn_out"
    fi
}

_post_all_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    _run_post_fn hook_tool_logging_post "$INPUT"
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_all_dispatch
    exit 0
fi
