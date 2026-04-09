#!/usr/bin/env bash
# hooks/lib/post-functions.sh
# Sourceable function definitions for the PostToolUse hooks.
#
# Each function follows the PostToolUse hook contract:
#   Input:  JSON string passed as $1
#   Exit 0: always (PostToolUse hooks are non-blocking)
#   stderr: suppressed via exec 2>/dev/null in each hook
#   stdout: optional feedback (always at least '{}' per bug #10463 workaround)
#
# Functions defined:
#   hook_exit_144_forensic_logger  — log forensic data on exit 144 (SIGURG timeout/cancellation)
#   hook_check_validation_failures — auto-create tracking issues for validate.sh failures
#   hook_track_cascade_failures    — track consecutive fix-fail cycles for cascade detection
#   hook_auto_format               — auto-format source files after Edit/Write tool calls
#   hook_tool_logging_pre          — log tool call (pre mode, hardcoded MODE=pre)
#   hook_tool_logging_post         — log tool call (post mode, hardcoded MODE=post)
#
# Usage:
#   source hooks/lib/post-functions.sh
#   hook_check_validation_failures "$INPUT_JSON"
#   hook_auto_format "$INPUT_JSON"

# Guard: only load once
[[ "${_POST_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_POST_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_POST_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_POST_FUNC_DIR/deps.sh"

# ---------------------------------------------------------------------------
# hook_exit_144_forensic_logger
# ---------------------------------------------------------------------------
# PostToolUse hook: log forensic data when a Bash tool call exits with 144.
# Exit 144 = SIGURG — indicates either a timeout or a cancellation.
#
# Reads the start timestamp written by pre-bash.sh (bash-start-ts-<hash>),
# computes elapsed time, classifies as timeout (>=70s) or cancellation (<70s),
# and appends a JSONL entry to exit-144-forensics.jsonl in the artifacts dir.
#
# If start timestamp is missing, writes entry with elapsed_s=-1, cause=unknown.
# If exit_code != 144 (or missing), returns immediately with zero I/O.
hook_exit_144_forensic_logger() {
    local INPUT="$1"

    # Fast path: parse exit_code — bail immediately if not 144.
    # PostToolUse provides .tool_response.exit_code (but only fires on exit 0).
    # PostToolUseFailure provides .error string like "...status code 144" (fires on non-zero).
    # Try both paths so this function works from either dispatcher.
    local EXIT_CODE
    EXIT_CODE=$(parse_json_field "$INPUT" '.tool_response.exit_code')
    if [[ -z "$EXIT_CODE" || "$EXIT_CODE" == "null" ]]; then
        # PostToolUseFailure path: extract exit code from error string
        local ERROR_MSG
        ERROR_MSG=$(parse_json_field "$INPUT" '.error')
        if [[ "$ERROR_MSG" == *"status code 144"* ]]; then
            EXIT_CODE="144"
        fi
    fi
    [[ "$EXIT_CODE" == "144" ]] || return 0

    # ERR trap for graceful degradation
    trap 'return 0' ERR

    # macOS-compatible millisecond timestamp (local copy to avoid dependency on pre-bash.sh)
    _forensic_get_ms() {
        local _ns
        _ns=$(date +%s%N 2>/dev/null) || _ns=""
        if [[ -n "$_ns" && "$_ns" != *N* ]]; then
            echo $(( _ns / 1000000 ))
        else
            python3 -c 'import time;print(int(time.time()*1e3))' 2>/dev/null || echo 0
        fi
    }

    # Extract command from input
    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')

    # Compute command hash to find the matching start timestamp
    local ARTIFACTS_DIR
    ARTIFACTS_DIR=$(get_artifacts_dir)

    local ELAPSED_S="-1"
    local CAUSE="unknown"

    if [[ -n "$COMMAND" ]]; then
        local CMD_HASH
        CMD_HASH=$(echo -n "$COMMAND" | hash_stdin | cut -c1-8)
        local TS_FILE="$ARTIFACTS_DIR/bash-start-ts-${CMD_HASH}"

        if [[ -f "$TS_FILE" ]]; then
            local START_MS
            START_MS=$(cat "$TS_FILE")
            local NOW_MS
            NOW_MS=$(_forensic_get_ms)

            if [[ -n "$START_MS" && "$START_MS" =~ ^[0-9]+$ && -n "$NOW_MS" && "$NOW_MS" =~ ^[0-9]+$ ]]; then
                local ELAPSED_MS=$(( NOW_MS - START_MS ))
                # Format as float with 1 decimal place
                ELAPSED_S=$(python3 -c "print(round(${ELAPSED_MS}/1000.0, 1))" 2>/dev/null || echo "-1")

                # Classify: >=70000ms = timeout, <70000ms = cancellation
                if (( ELAPSED_MS >= 70000 )); then
                    CAUSE="timeout"
                else
                    CAUSE="cancellation"
                fi
            fi
        fi
    fi

    # Generate ISO8601 timestamp
    local TIMESTAMP
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

    # Write JSONL entry via file append (NOT stdout — stdout is captured as agent feedback)
    local JSONL_FILE="$ARTIFACTS_DIR/exit-144-forensics.jsonl"
    local ENTRY
    ENTRY=$(python3 -c "
import json, sys
entry = {
    'timestamp': sys.argv[1],
    'command': sys.argv[2],
    'elapsed_s': float(sys.argv[3]),
    'cause': sys.argv[4],
    'cwd': sys.argv[5]
}
print(json.dumps(entry))
" "$TIMESTAMP" "${COMMAND:-unknown}" "$ELAPSED_S" "$CAUSE" "$PWD" 2>/dev/null)

    if [[ -n "$ENTRY" ]]; then
        printf '%s\n' "$ENTRY" >> "$JSONL_FILE"
    fi

    # ── Agent-visible reminder: use test-batched.sh for long-running test commands ──
    # Detect test commands that should have used test-batched.sh to avoid exit 144.
    # Output goes to stdout → becomes agent feedback in Claude Code.
    if [[ -n "$COMMAND" && "$CAUSE" == "timeout" ]]; then
        local _IS_TEST_CMD=""
        # Match broad test commands (make test*, validate.sh, broad pytest runs)
        case "$COMMAND" in
            *"make test"*|*"validate.sh"*) _IS_TEST_CMD=1 ;;
        esac
        # Match pytest/poetry run pytest — but NOT targeted single-test runs (file.py::test_name)
        if [[ -z "$_IS_TEST_CMD" && "$COMMAND" == *"pytest"* && "$COMMAND" != *"::"* ]]; then
            _IS_TEST_CMD=1
        fi
        if [[ -n "$_IS_TEST_CMD" ]]; then
            local _REPO_ROOT
            _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
            cat <<'REMINDER'

⚠️  EXIT 144 (SIGURG timeout) on a test command.
    Long-running test commands MUST use test-batched.sh to avoid this.

    Example:
      .claude/scripts/dso test-batched.sh --timeout=50 "make test-unit-only"

    See CLAUDE.md rule #16: "Use test-batched.sh for test commands expected to exceed 60 seconds."
    Re-run this command using test-batched.sh now.
REMINDER
        fi
    fi

    trap - ERR
    return 0
}

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
    local _CHECK_SCRIPT="$CLAUDE_PLUGIN_ROOT/hooks/check-validation-failures.sh"
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
    local _TRACK_SCRIPT="$CLAUDE_PLUGIN_ROOT/hooks/track-cascade-failures.sh"
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
    local _FORMAT_SCRIPT="$CLAUDE_PLUGIN_ROOT/hooks/auto-format.sh"
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
# ---------------------------------------------------------------------------
# hook_extract_agent_suggestion
# ---------------------------------------------------------------------------
# PostToolUse hook: extract the first SUGGESTION: sentinel from an Agent tool
# return and record it via suggestion-record.sh.
#
# Only fires on Agent tool returns. Extracts the first line matching:
#   SUGGESTION: <text>
# from the tool_response.output field. Calls suggestion-record.sh with the
# extracted text. Warns to stderr on malformed sentinel (empty text after colon)
# but does not crash.
#
# Uses python3 for output extraction (handles multi-line JSON strings reliably).
hook_extract_agent_suggestion() {
    local INPUT="$1"
    trap 'return 0' ERR

    # Only act on Agent tool returns
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Agent" ]]; then
        return 0
    fi

    # Extract output text using python3 (handles newline escapes in JSON strings)
    local OUTPUT_TEXT=""
    OUTPUT_TEXT=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    tr = d.get('tool_response', {})
    out = tr.get('output', '') if isinstance(tr, dict) else ''
    print(out)
except Exception:
    pass
" "$INPUT" 2>/dev/null) || OUTPUT_TEXT=""

    if [[ -z "$OUTPUT_TEXT" ]]; then
        return 0
    fi

    # Find first line starting with SUGGESTION:
    local SUGGESTION_LINE=""
    while IFS= read -r _line; do
        if [[ "$_line" == "SUGGESTION:"* ]]; then
            SUGGESTION_LINE="$_line"
            break
        fi
    done <<< "$OUTPUT_TEXT"

    if [[ -z "$SUGGESTION_LINE" ]]; then
        # No SUGGESTION: sentinel found — nothing to record
        return 0
    fi

    # Extract text after "SUGGESTION: " (trim leading space)
    local SUGGESTION_TEXT="${SUGGESTION_LINE#SUGGESTION:}"
    # Trim leading whitespace
    SUGGESTION_TEXT="${SUGGESTION_TEXT#"${SUGGESTION_TEXT%%[![:space:]]*}"}"

    # Warn on malformed sentinel (empty text after colon)
    if [[ -z "$SUGGESTION_TEXT" ]]; then
        echo "post-agent hook: malformed SUGGESTION: sentinel — no text after colon (skipping)" >&2
        return 0
    fi

    # Resolve suggestion-record command.
    # DSO_SUGGESTION_RECORD_CMD overrides for testing (set to e.g. "/mock/dso suggestion-record").
    # Otherwise: prefer .claude/scripts/dso shim (via git-resolved repo root),
    # falling back to direct plugin script path.
    local _SUGG_CMD=""
    if [[ -n "${DSO_SUGGESTION_RECORD_CMD:-}" ]]; then
        _SUGG_CMD="$DSO_SUGGESTION_RECORD_CMD"
    else
        local _REPO_ROOT_FOR_SHIM
        _REPO_ROOT_FOR_SHIM=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$_REPO_ROOT_FOR_SHIM" && -x "$_REPO_ROOT_FOR_SHIM/.claude/scripts/dso" ]]; then
            _SUGG_CMD="$_REPO_ROOT_FOR_SHIM/.claude/scripts/dso suggestion-record"
        elif [[ -x "$CLAUDE_PLUGIN_ROOT/scripts/suggestion-record.sh" ]]; then # shim-exempt: fallback for test environments without shim
            _SUGG_CMD="$CLAUDE_PLUGIN_ROOT/scripts/suggestion-record.sh" # shim-exempt: fallback for test environments without shim
        fi
    fi

    if [[ -n "$_SUGG_CMD" ]]; then
        # shellcheck disable=SC2086
        $_SUGG_CMD \
            --source="post-agent-hook" \
            --observation="$SUGGESTION_TEXT" \
            2>/dev/null || true
    fi

    trap - ERR
    return 0
}

# hook_tool_logging_pre
# ---------------------------------------------------------------------------
# PreToolUse hook: log tool call with MODE hardcoded to "pre".
# tool-logging.sh accepts MODE as $1; this wrapper hardcodes pre.
hook_tool_logging_pre() {
    local INPUT="$1"
    # Defense-in-depth: skip if logging is disabled (dispatcher also checks)
    test -f "$HOME/.claude/tool-logging-enabled" || return 0
    local _LOG_SCRIPT="$CLAUDE_PLUGIN_ROOT/hooks/tool-logging.sh"
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
    # Defense-in-depth: skip if logging is disabled (dispatcher also checks)
    test -f "$HOME/.claude/tool-logging-enabled" || return 0
    local _HOOK_HAS_OUTPUT=""
    trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi' EXIT

    local _LOG_SCRIPT="$CLAUDE_PLUGIN_ROOT/hooks/tool-logging.sh"
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
