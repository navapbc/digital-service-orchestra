#!/usr/bin/env bash
# hooks/dispatchers/pre-bash.sh
# PreToolUse Bash dispatcher: sources all Bash hook functions and runs them
# sequentially. Stops at the first function that returns 2 (block/deny).
#
# Replaces multiple separate settings.json entries with a single dispatcher entry:
#   run-hook.sh dispatchers/pre-bash.sh
#
# Hook execution order (per task spec):
#   1. hook_test_failure_guard (block commit when test status files contain FAILED)
#   2. hook_commit_failure_tracker
#   3. hook_review_bypass_sentinel (block bypass vectors: --no-verify, hooksPath, commit-tree)
#   4. hook_worktree_bash_guard
#   5. hook_worktree_edit_guard
#   6. hook_review_integrity_guard
#   7. hook_blocked_test_command (block broad test commands, redirect to validate.sh)
#   8. hook_record_test_status_guard — block direct record-test-status.sh calls (allow --attest)
#   9. hook_tickets_tracker_bash_guard — block Bash commands referencing .tickets-tracker/
#
# NOTE: hook_review_gate was removed in Story 1idf. Review gate enforcement is
#   now two-layer:
#   - Layer 1: hooks/pre-commit-review-gate.sh (git pre-commit hook)
#     enforces allowlist + review-status + diff hash check at git commit time.
#   - Layer 2: hook_review_bypass_sentinel (this dispatcher, step 3)
#     blocks commands that attempt to bypass the git pre-commit hook.
#
# Removed (optimization): logging hook (moved to all-tools dispatcher), use-guard hook
#
# Returns: 0 if all hooks allow, 2 if any hook blocks.

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source shared ERR handler (fail-open: if missing, continue without trap)
if [[ -f "${HOOKS_LIB_DIR}/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${HOOKS_LIB_DIR}/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "pre-bash.sh"
fi

# macOS-compatible millisecond timestamp (date +%s%N unavailable on macOS)
# Guarantees a numeric result — falls back to python3, then 0.
_get_ms() {
    local _ns
    _ns=$(date +%s%N 2>/dev/null) || _ns=""
    if [[ -n "$_ns" && "$_ns" != *N* ]]; then
        echo $(( _ns / 1000000 ))
    else
        python3 -c 'import time;print(int(time.time()*1e3))' 2>/dev/null || echo 0
    fi
}

# Source the dispatcher framework (provides run_hooks — kept for reference/reuse)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all hook functions
source "$HOOKS_LIB_DIR/pre-bash-functions.sh"

# Source bypass sentinel (Layer 2 of the two-layer review gate)
source "$HOOKS_LIB_DIR/review-gate-bypass-sentinel.sh"

# Run all hook functions sequentially.
# Stops at first function that returns 2 (block).
# Non-zero exit codes other than 2 are intentionally allowed to fall through
# (fail-open design): each hook function has its own ERR trap that logs the
# error and returns 0, so a non-2 exit from _run_hook_fn means the hook chose
# to allow. This matches the original per-hook ERR-trap fail-open contract.
# REVIEW-DEFENSE: Fail-open is deliberate — each hook's ERR trap (return 0)
# ensures non-2 exits are safe. Blocking on unknown codes would break the
# fail-open contract and risk false denials on transient errors.
# Only executed when this script is run directly (not sourced).
_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0

    # Per-function timing (enabled by ~/.claude/hook-timing-enabled)
    if [[ -f "$HOME/.claude/hook-timing-enabled" ]]; then
        local _fn_start
        _fn_start=$(_get_ms)
        "$fn_name" "$json_input" || fn_exit=$?
        local _fn_end
        _fn_end=$(_get_ms)
        printf '%s\t  %s\t%dms\texit=%d\n' \
            "$(date +%H:%M:%S)" "$fn_name" "$((_fn_end - _fn_start))" "$fn_exit" \
            >> "${HOOK_TIMING_LOG:-/tmp/hook-timing.log}" 2>/dev/null
    else
        "$fn_name" "$json_input" || fn_exit=$?
    fi

    return "$fn_exit"
}

_pre_bash_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    for _HOOK_FN in \
        hook_test_failure_guard \
        hook_commit_failure_tracker \
        hook_review_bypass_sentinel \
        hook_worktree_bash_guard \
        hook_worktree_edit_guard \
        hook_review_integrity_guard \
        hook_blocked_test_command \
        hook_record_test_status_guard \
        hook_tickets_tracker_bash_guard
    do
        local _fn_exit=0
        _run_hook_fn "$_HOOK_FN" "$INPUT" || _fn_exit=$?
        if [[ "$_fn_exit" -eq 2 ]]; then
            return 2
        fi
    done

    # Record start timestamp for exit-144 forensic logger.
    # Uses command-hash-keyed filename to avoid race conditions with concurrent Bash calls.
    local _cmd
    _cmd=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -n "$_cmd" ]]; then
        local _cmd_hash
        _cmd_hash=$(echo -n "$_cmd" | hash_stdin | cut -c1-8)
        local _artifacts_dir
        _artifacts_dir=$(get_artifacts_dir)
        _get_ms > "$_artifacts_dir/bash-start-ts-${_cmd_hash}" 2>/dev/null || true
    fi

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
# Detection: BASH_SOURCE[0] == $0 means we were invoked directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _dispatch_exit=0
    _pre_bash_dispatch || _dispatch_exit=$?
    # Disable both ERR and EXIT traps before exiting. Guard functions set ERR
    # traps referencing function-local HOOK_ERROR_LOG; on happy-path return the
    # trap leaks into this scope. Without clearing ERR, the leaked trap fires on
    # the non-zero _dispatch_exit and produces spurious 'No such file' and
    # 'return from function' trailers (bug 1c89-68ee). The || above also
    # prevents the ERR trap from firing mid-capture of the dispatch return code.
    trap - ERR EXIT 2>/dev/null || true
    exit "$_dispatch_exit"
fi
