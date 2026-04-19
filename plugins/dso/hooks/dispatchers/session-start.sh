#!/usr/bin/env bash
# hooks/dispatchers/session-start.sh
# SessionStart dispatcher: sources all 4 session-start hook functions and runs them.
#
# Replaces separate settings.json SessionStart entries with a single dispatcher:
#   run-hook.sh dispatchers/session-start.sh
#
# Hook execution order:
#   0. hook_cleanup_orphaned_processes — kill stale nohup orphans (>30 min old)
#   0a. hook_cleanup_stale_nohup      — reap stale/hung nohup processes from registry
#   1. hook_inject_using_dso          — inject using-dso skill context
#   2. hook_session_safety_check      — analyze hook error log, create bugs for recurring errors
#   3. hook_post_compact_review_check — warn about review state after compaction
#   4. hook_check_artifact_versions   — warn when host-project artifacts are stale
#
# Returns: 0 always (all 6 hooks are informational/output-only; none block)

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Source the dispatcher framework (provides run_hooks — kept for reference/reuse)
source "$HOOKS_LIB_DIR/dispatcher.sh"

# Source all session-start hook functions
source "$HOOKS_LIB_DIR/session-misc-functions.sh"

_run_hook_fn() {
    local fn_name="$1"
    local json_input="$2"
    local fn_exit=0
    "$fn_name" "$json_input" || fn_exit=$?
    return "$fn_exit"
}

_session_start_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    for _HOOK_FN in \
        hook_cleanup_orphaned_processes \
        hook_cleanup_stale_nohup \
        hook_inject_using_dso \
        hook_session_safety_check \
        hook_post_compact_review_check \
        hook_check_artifact_versions
    do
        local _fn_exit=0
        _run_hook_fn "$_HOOK_FN" "$INPUT" || _fn_exit=$?
        # Session-start hooks are informational — never block on non-zero exit
        # hook_post_compact_review_check may set ERR trap which returns 0 on error
    done

    return 0
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _session_start_dispatch
    exit $?
fi
