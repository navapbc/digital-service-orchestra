#!/usr/bin/env bash
# hooks/dispatchers/post-agent.sh
# PostToolUse Agent dispatcher: extracts SUGGESTION: sentinels from sub-agent returns.
#
# Hook execution order:
#   1. hook_extract_agent_suggestion  — extract first SUGGESTION: line and call suggestion-record.sh
#
# PostToolUse hooks always exit 0 (non-blocking).
# Always emits at least '{}' on stdout per Claude Code bug #10463 workaround.

# DEFENSE-IN-DEPTH: Guarantee exit 0 and non-empty stdout on any unexpected failure.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source the dispatcher framework (provides run_hooks)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all post hook functions (includes hook_extract_agent_suggestion)
source "$HOOKS_LIB_DIR/post-functions.sh"

# Run all Agent post-hook functions sequentially.
# PostToolUse hooks are non-blocking (always return 0).
# stderr is NOT suppressed so that warning messages (e.g. malformed sentinel)
# are visible to the agent.
_run_post_fn() {
    local fn_name="$1"
    local json_input="$2"
    local _fn_out=""
    _fn_out=$("$fn_name" "$json_input") || true
    if [[ -n "$_fn_out" ]] && [[ "$_fn_out" != "{}" ]]; then
        _HOOK_HAS_OUTPUT=1
        printf '%s\n' "$_fn_out"
    fi
}

_post_agent_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    _run_post_fn hook_extract_agent_suggestion "$INPUT"
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_agent_dispatch
    exit 0
fi
