#!/usr/bin/env bash
# hooks/lib/pre-edit-write-functions.sh
# Sourceable function definitions for the PreToolUse Edit/Write hooks.
#
# Each function follows the hook contract:
#   Input:  JSON string passed as $1
#   Return 0: allow — continue to next hook
#   Return 2: block/deny — dispatcher stops, outputs permissionDecision
#   stderr: warnings (always allowed; passed through by dispatcher)
#   stdout: permissionDecision message (only consumed when return 2)
#
# Functions defined:
#   hook_worktree_edit_guard     — block Edit/Write targeting main repo from worktree
#   hook_cascade_circuit_breaker — block Edit/Write when cascade failure threshold reached
#   hook_title_length_validator  — block Write/Edit setting ticket titles > 255 chars
#
# Note: hook_worktree_edit_guard is defined in pre-bash-functions.sh and re-exported
# here via the source chain. This ensures both dispatchers (pre-bash and pre-edit/write)
# share the same function body without duplication.
#
# Usage:
#   source hooks/lib/pre-edit-write-functions.sh
#   hook_cascade_circuit_breaker "$INPUT_JSON"
#   hook_title_length_validator "$INPUT_JSON"

# Guard: only load once
[[ "${_PRE_EDIT_WRITE_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_PRE_EDIT_WRITE_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_PRE_EDIT_WRITE_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PRE_EDIT_WRITE_FUNC_DIR/deps.sh"

# Source pre-bash-functions to get hook_worktree_edit_guard
# (idempotent via its own guard)
source "$_PRE_EDIT_WRITE_FUNC_DIR/pre-bash-functions.sh"

# ---------------------------------------------------------------------------
# hook_cascade_circuit_breaker
# ---------------------------------------------------------------------------
# PreToolUse hook: block Edit/Write when fix cascade threshold is reached.
#
# Enforces CLAUDE.md rule 13:
#   "Never continue fixing after 5 cascading failures — run /dso:fix-cascade-recovery"
#
# Passthrough (never blocked):
#   - .tickets/ files (issue tracking)
#   - CLAUDE.md and .claude/ files (configuration)
#   - /tmp/ files (temporary state)
#   - ~/.claude/ files (user config)
#   - KNOWN-ISSUES.md and MEMORY.md (documentation)
#
# Paired with track-cascade-failures.sh (PostToolUse on Bash).
hook_cascade_circuit_breaker() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    local _CASCADE_FN_ERR_LOG="/tmp/cascade-circuit-breaker-fn-err.log"
    # REVIEW-DEFENSE: JSONL log uses %s for $BASH_COMMAND which may contain quotes — accepted
    # tradeoff: proper escaping would require a function call, adding complexity to a trap that
    # must be minimal. The plaintext log (_CASCADE_FN_ERR_LOG) is the primary diagnostic target.
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"cascade-circuit-breaker\",\"line\":%s,\"cmd\":\"%s\"}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" "$BASH_COMMAND" >> "$HOOK_ERROR_LOG" 2>/dev/null; printf "[%s] ERR trap line=%s cmd=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" "$BASH_COMMAND" >> "$_CASCADE_FN_ERR_LOG" 2>/dev/null; return 0' ERR

    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]]; then
        return 0
    fi

    # --- Check file path for passthrough ---
    local FILE_PATH
    FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')

    # Allow non-code edits (issue tracking, config, docs, temp files).
    # Split into two case blocks because $HOME expansion does not work
    # inside a single case pattern list with | separators.
    case "$FILE_PATH" in
        */.tickets/*|*/CLAUDE.md|*/.claude/*|/tmp/*)
            return 0
            ;;
    esac
    case "$FILE_PATH" in
        "$HOME/.claude/"*|*/KNOWN-ISSUES.md|*/MEMORY.md)
            return 0
            ;;
    esac

    # --- Resolve worktree-scoped state directory ---
    local WORKTREE_ROOT
    WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$WORKTREE_ROOT" ]]; then
        return 0
    fi

    local WT_HASH
    if command -v md5 &>/dev/null; then
        WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5)
    elif command -v md5sum &>/dev/null; then
        WT_HASH=$(echo -n "$WORKTREE_ROOT" | md5sum | cut -d' ' -f1)
    else
        WT_HASH=$(echo -n "$WORKTREE_ROOT" | tr '/' '_')
    fi

    local STATE_DIR="/tmp/claude-cascade-${WT_HASH}"
    local COUNTER_FILE="$STATE_DIR/counter"

    # --- No counter file means no cascade ---
    if [[ ! -f "$COUNTER_FILE" ]]; then
        return 0
    fi

    # --- Read counter ---
    local COUNTER
    COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    if { [[ "$COUNTER" =~ ^[0-9]+$ ]]; } 2>/dev/null; then
        : # valid numeric counter
    else
        return 0
    fi

    # --- Enforce threshold ---
    local CASCADE_THRESHOLD=5

    if (( COUNTER >= CASCADE_THRESHOLD )); then
        echo "BLOCKED: Fix cascade (rule 13). $COUNTER consecutive fixes produced different errors." >&2
        echo "Run /dso:fix-cascade-recovery to analyze root cause and reset." >&2
        echo "Manual reset: echo 0 > $COUNTER_FILE" >&2
        trap - ERR; return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_title_length_validator
# ---------------------------------------------------------------------------
# PreToolUse hook: block Write or Edit calls that would set a ticket title
# longer than 255 characters in a .tickets/ file.
#
# Jira's summary field has a 255-character limit. Enforcing this at write time
# prevents sync-time failures.
#
# Logic:
#   1. Only fires on Write or Edit tool calls
#   2. Only inspects file paths that contain /.tickets/
#   3. For Write: scans the full 'content' field for a markdown title line (# ...)
#   4. For Edit: scans the 'new_string' field for a markdown title line
#   5. If a title line is found and its text exceeds 255 chars: BLOCKED (return 2)
#   6. All other cases: return 0 (fail open)
hook_title_length_validator() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"title-length-validator\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    local TITLE_MAX=255

    # Only act on Write or Edit tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
        return 0
    fi

    # Get the file path
    local FILE_PATH
    FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
    if [[ -z "$FILE_PATH" ]]; then
        return 0
    fi

    # Only act on files inside a .tickets/ directory
    if [[ "$FILE_PATH" != *"/.tickets/"* ]]; then
        return 0
    fi

    # Extract the text content to scan for a title line
    # For Write: use 'content'; for Edit: use 'new_string'
    local FIELD
    if [[ "$TOOL_NAME" == "Write" ]]; then
        FIELD='.tool_input.content'
    else
        FIELD='.tool_input.new_string'
    fi

    # Extract text content using bash-native parse_json_field (no jq dependency).
    local TEXT_CONTENT=""
    TEXT_CONTENT=$(parse_json_field "$INPUT" "$FIELD")

    if [[ -z "$TEXT_CONTENT" ]]; then
        return 0
    fi

    # Find the first markdown H1 title line (# Title text)
    # We process the content line by line (handling \n escape sequences if present)
    # by normalizing escaped newlines first.
    local TITLE_LINE=""
    while IFS= read -r line; do
        # Strip leading carriage return (Windows line endings)
        line="${line%$'\r'}"
        if [[ "$line" =~ ^#[[:space:]](.*)$ ]]; then
            TITLE_LINE="${BASH_REMATCH[1]}"
            break
        fi
    done <<< "$(printf '%b' "$TEXT_CONTENT")"

    # No title line found — nothing to validate
    if [[ -z "$TITLE_LINE" ]]; then
        return 0
    fi

    # Measure title length
    local TITLE_LEN=${#TITLE_LINE}

    if (( TITLE_LEN > TITLE_MAX )); then
        echo "BLOCKED [title-length-validator]: Ticket title is ${TITLE_LEN} characters (max ${TITLE_MAX})." >&2
        echo "Jira's summary field has a ${TITLE_MAX}-character limit." >&2
        echo "Please shorten the title before saving: ${FILE_PATH}" >&2
        trap - ERR; return 2
    fi

    return 0
}
