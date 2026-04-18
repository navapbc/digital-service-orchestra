#!/usr/bin/env bash
# hooks/dispatchers/post-bash.sh
# PostToolUse Bash dispatcher: sources all 3 Bash post-hook functions and runs them.
#
# Replaces 3 separate settings.json entries with a single dispatcher entry:
#   run-hook.sh dispatchers/post-bash.sh
#
# Hook execution order:
#   1. hook_exit_144_forensic_logger
#   2. (removed: hook_check_validation_failures — created spurious tickets from stale validation state)
#   3. hook_track_cascade_failures
#
# Removed (optimization): logging hook (moved to all-tools dispatcher)
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
_HOOKS_LIB_DIR="${_HOOKS_LIB_DIR:-${HOOKS_LIB_DIR}}"
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "post-bash.sh"
else
    trap 'exit 0' ERR
fi

# Source the dispatcher framework (provides run_hooks)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all post hook functions
source "$HOOKS_LIB_DIR/post-functions.sh"

# Run all Bash post-hook functions sequentially.
# PostToolUse hooks are non-blocking (always return 0).
# Accumulate output from all hooks; emit at least '{}' if none.
_run_post_fn() {
    local fn_name="$1"
    local json_input="$2"
    local _fn_out=""
    _fn_out=$("$fn_name" "$json_input" 2>/dev/null) || true
    if [[ -n "$_fn_out" ]] && [[ "$_fn_out" != "{}" ]]; then
        _HOOK_HAS_OUTPUT=1
        printf '%s\n' "$_fn_out"
    fi
}

_post_bash_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    _run_post_fn hook_exit_144_forensic_logger "$INPUT"
    _run_post_fn hook_track_cascade_failures "$INPUT"
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_bash_dispatch
    exit 0
fi
