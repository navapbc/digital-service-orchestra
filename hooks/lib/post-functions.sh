#!/usr/bin/env bash
# lockpick-workflow/hooks/lib/post-functions.sh
# Sourceable function definitions for the PostToolUse hooks.
#
# Each function follows the PostToolUse hook contract:
#   Input:  JSON string passed as $1
#   Exit 0: always (PostToolUse hooks are non-blocking)
#   stderr: suppressed via exec 2>/dev/null in each hook
#   stdout: optional feedback (always at least '{}' per bug #10463 workaround)
#
# Functions defined:
#   hook_check_validation_failures — auto-create tracking issues for validate.sh failures
#   hook_track_cascade_failures    — track consecutive fix-fail cycles for cascade detection
#   hook_auto_format               — auto-format source files after Edit/Write tool calls
#   hook_tool_logging_pre          — log tool call (pre mode, hardcoded MODE=pre)
#   hook_tool_logging_post         — log tool call (post mode, hardcoded MODE=post)
#
# Usage:
#   source lockpick-workflow/hooks/lib/post-functions.sh
#   hook_check_validation_failures "$INPUT_JSON"
#   hook_auto_format "$INPUT_JSON"

# Guard: only load once
[[ "${_POST_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_POST_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_POST_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_POST_FUNC_DIR/deps.sh"

# ---------------------------------------------------------------------------
# hook_check_validation_failures
# ---------------------------------------------------------------------------
# PostToolUse hook: auto-create tracking issues for validate.sh failures.
# Delegates to the original hook script to avoid code duplication.
hook_check_validation_failures() {
    local INPUT="$1"
    local _HOOK_HAS_OUTPUT=""
    trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi' EXIT

    # Delegate to original script (which has all the logic)
    local _CHECK_SCRIPT="$_POST_FUNC_DIR/../check-validation-failures.sh"
    if [[ -x "$_CHECK_SCRIPT" ]]; then
        local _output _exit=0
        _output=$(printf '%s' "$INPUT" | bash "$_CHECK_SCRIPT" 2>/dev/null) || _exit=0
        if [[ -n "$_output" ]]; then
            _HOOK_HAS_OUTPUT=1
            printf '%s\n' "$_output"
        fi
    fi

    trap - EXIT
    return 0
}

# ---------------------------------------------------------------------------
# hook_track_cascade_failures
# ---------------------------------------------------------------------------
# PostToolUse hook: track consecutive fix-fail cycles.
# Delegates to the original hook script to avoid code duplication.
hook_track_cascade_failures() {
    local INPUT="$1"
    local _HOOK_HAS_OUTPUT=""
    trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi' EXIT

    # Delegate to original script (which has all the logic)
    local _TRACK_SCRIPT="$_POST_FUNC_DIR/../track-cascade-failures.sh"
    if [[ -x "$_TRACK_SCRIPT" ]]; then
        local _output _exit=0
        _output=$(printf '%s' "$INPUT" | bash "$_TRACK_SCRIPT" 2>/dev/null) || _exit=0
        if [[ -n "$_output" ]] && [[ "$_output" != "{}" ]]; then
            _HOOK_HAS_OUTPUT=1
            printf '%s\n' "$_output"
        fi
    fi

    trap - EXIT
    return 0
}

# ---------------------------------------------------------------------------
# hook_auto_format
# ---------------------------------------------------------------------------
# PostToolUse hook: auto-format source files after Edit/Write tool calls.
# Delegates to the original hook script to avoid code duplication.
hook_auto_format() {
    local INPUT="$1"
    local _HOOK_HAS_OUTPUT=""
    trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi' EXIT

    # Delegate to original script (which has all the logic)
    local _FORMAT_SCRIPT="$_POST_FUNC_DIR/../auto-format.sh"
    if [[ -x "$_FORMAT_SCRIPT" ]]; then
        local _output _exit=0
        _output=$(printf '%s' "$INPUT" | bash "$_FORMAT_SCRIPT" 2>/dev/null) || _exit=0
        if [[ -n "$_output" ]] && [[ "$_output" != "{}" ]]; then
            _HOOK_HAS_OUTPUT=1
            printf '%s\n' "$_output"
        fi
    fi

    trap - EXIT
    return 0
}


# hook_ticket_sync_push — REMOVED (epic 3igl)
# Ticket sync infrastructure removed. Tickets now flow through normal git commits.

# ---------------------------------------------------------------------------
# hook_tool_logging_pre
# ---------------------------------------------------------------------------
# PreToolUse hook: log tool call with MODE hardcoded to "pre".
# tool-logging.sh accepts MODE as $1; this wrapper hardcodes pre.
hook_tool_logging_pre() {
    local INPUT="$1"
    local _LOG_SCRIPT="$_POST_FUNC_DIR/../tool-logging.sh"
    if [[ -x "$_LOG_SCRIPT" ]]; then
        printf '%s' "$INPUT" | bash "$_LOG_SCRIPT" pre 2>/dev/null || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# hook_tool_logging_post
# ---------------------------------------------------------------------------
# PostToolUse hook: log tool call with MODE hardcoded to "post".
# tool-logging.sh accepts MODE as $1; this wrapper hardcodes post.
hook_tool_logging_post() {
    local INPUT="$1"
    local _HOOK_HAS_OUTPUT=""
    trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi' EXIT

    local _LOG_SCRIPT="$_POST_FUNC_DIR/../tool-logging.sh"
    if [[ -x "$_LOG_SCRIPT" ]]; then
        local _output _exit=0
        _output=$(printf '%s' "$INPUT" | bash "$_LOG_SCRIPT" post 2>/dev/null) || _exit=0
        if [[ -n "$_output" ]] && [[ "$_output" != "{}" ]]; then
            _HOOK_HAS_OUTPUT=1
            printf '%s\n' "$_output"
        fi
    fi

    trap - EXIT
    return 0
}
