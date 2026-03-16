#!/usr/bin/env bash
# hooks/lib/dispatcher.sh
# Dispatcher framework for Claude Code PreToolUse hook chains.
#
# Provides run_hooks() — a sequential hook runner that:
#   - Calls each hook script with the JSON input on stdin
#   - Stops at the first hook that exits 2 (block/deny)
#   - Passes through the blocking hook's stdout as the permissionDecision
#   - Returns 0 if all hooks allow, 2 if any hook blocks
#
# Hook script contract:
#   Input:  JSON string passed on stdin
#   Exit 0: allow — continue to next hook
#   Exit 2: block/deny — stop dispatcher, propagate stdout as permissionDecision
#   stderr: warnings (always allowed; passed through by dispatcher)
#   stdout: permissionDecision JSON (only consumed when exit 2)
#
# Usage:
#   source hooks/lib/dispatcher.sh
#   run_hooks "$INPUT_JSON" /path/to/hook1.sh /path/to/hook2.sh
#
# Returns: 0 if all hooks allowed, 2 if any hook blocked

# Guard: only load once
[[ "${_DISPATCHER_LOADED:-}" == "1" ]] && return 0
_DISPATCHER_LOADED=1

# --- run_hooks ---
# Run a sequence of hook scripts sequentially.
# Stops at the first hook that exits 2 (block/deny).
#
# Usage: run_hooks <json_input> <hook1> [hook2] ...
#   json_input — the JSON string to pass to each hook on stdin
#   hookN      — path to an executable hook script
#
# Returns:
#   0  — all hooks exited 0 (allow)
#   2  — a hook exited 2 (block); that hook's stdout is echoed to our stdout
run_hooks() {
    local json_input="$1"
    shift

    local hook
    for hook in "$@"; do
        # Skip non-existent or non-executable hooks gracefully
        if [[ ! -x "$hook" ]]; then
            continue
        fi

        local hook_output=""
        local hook_exit=0
        # Pass JSON on stdin; capture stdout; let stderr flow through
        hook_output=$(printf '%s' "$json_input" | bash "$hook") || hook_exit=$?

        if [[ "$hook_exit" -eq 2 ]]; then
            # Propagate the blocking hook's stdout as the permissionDecision
            if [[ -n "$hook_output" ]]; then
                printf '%s' "$hook_output"
            fi
            return 2
        fi
        # Any other non-zero exit (unexpected): treat as allow (fail-open)
    done

    return 0
}
