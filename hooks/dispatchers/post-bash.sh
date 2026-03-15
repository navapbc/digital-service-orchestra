#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/post-bash.sh
# PostToolUse Bash dispatcher: sources Bash post-hook functions and runs them.
#
# Replaces separate settings.json entries with a single dispatcher entry:
#   run-hook.sh dispatchers/post-bash.sh
#
# Hook execution order:
#   1. hook_exit_144_forensic_logger
#   2. hook_check_validation_failures (only for test/lint/validate commands)
#   3. hook_track_cascade_failures (only for test/lint/validate commands)
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

# Cache REPO_ROOT once for all hooks (avoids redundant git rev-parse calls)
export REPO_ROOT
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Source the dispatcher framework (provides run_hooks)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source post hook functions
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

    # Exit-144 forensics always runs (lightweight: checks exit_code field first)
    _run_post_fn hook_exit_144_forensic_logger "$INPUT"

    # Early-exit: validation/cascade checks only matter for test/lint/validate commands
    local _cmd=""
    if [[ "$INPUT" =~ \"command\"[[:space:]]*:[[:space:]]*\" ]]; then
        local _after="${INPUT#*\"command\"*:*\"}"
        _cmd="${_after%%\"*}"
    fi
    case "$_cmd" in
        *test*|*lint*|*pytest*|*ruff*|*mypy*|*validate*|*make*)
            _run_post_fn hook_check_validation_failures "$INPUT"
            _run_post_fn hook_track_cascade_failures "$INPUT"
            ;;
    esac
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_bash_dispatch
    exit 0
fi
