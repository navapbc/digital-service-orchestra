#!/usr/bin/env bash
# hooks/dispatchers/post-all.sh
# PostToolUse catch-all dispatcher: timing instrumentation for all tools.
# No blocking post-hooks. Kept for timing support.
#
# PostToolUse hooks always exit 0 (non-blocking).
# Always emits at least '{}' on stdout per Claude Code bug #10463 workaround.

# DEFENSE-IN-DEPTH: Guarantee exit 0 and non-empty stdout on any unexpected failure.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source shared ERR handler (fail-open: if missing, keep original silent trap behavior)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "post-all.sh"
else
    trap 'exit 0' ERR
fi

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

# Source post hook functions (none used currently; sourced for future hooks and ERR coverage)
source "$HOOKS_LIB_DIR/post-functions.sh"

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
