#!/usr/bin/env bash
# .claude/hooks/tool-logging.sh
# PreToolUse / PostToolUse hook: log every tool call as JSONL for pattern analysis.
#
# Usage (via run-hook.sh):
#   tool-logging.sh pre   — called by PreToolUse empty-matcher
#   tool-logging.sh post  — called by PostToolUse empty-matcher
#
# Toggle: create/remove ~/.claude/tool-logging-enabled (use scripts/toggle-tool-logging.sh)
# Log location: ~/.claude/logs/tool-use-YYYY-MM-DD.jsonl
#
# Schema: {"ts":"ISO-8601","epoch_ms":N,"session_id":"...","tool_name":"...","hook_type":"pre|post","tool_input_summary":"...","exit_status":N}
# Note: exit_status is only present in post entries.
#

# DEFENSE-IN-DEPTH: Guarantee exit 0 and suppress stderr.
# For pre mode: EXIT trap must produce ZERO bytes on stdout.
# For post mode: EXIT trap outputs "{}" per Claude Code bug #10463 workaround.
exec 2>/dev/null

MODE="${1:-pre}"

if [[ "$MODE" == "post" ]]; then
    _HOOK_HAS_OUTPUT=""
    trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
else
    # pre mode: never produce stdout under any path
    trap 'exit 0' EXIT
fi

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Fast path: exit immediately if logging is not enabled
test -f "$HOME/.claude/tool-logging-enabled" || exit 0

# --- Read hook input ---
INPUT=$(cat)

TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
TOOL_INPUT_RAW=$(parse_json_object "$INPUT" '.tool_input')
[[ -z "$TOOL_INPUT_RAW" ]] && TOOL_INPUT_RAW="{}"
SESSION_ID=$(parse_json_field "$INPUT" '.session_id')
# PostToolUse only fires on success; exit code is not at top level.
# For Bash, read from tool_response if available (for richer logging).
EXIT_STATUS=""
if [[ "$MODE" == "post" ]]; then
    EXIT_STATUS=$(parse_json_field "$INPUT" '.tool_response.exit_code')
fi

# Session ID fallback: use a file-based session marker if not in input
if [[ -z "$SESSION_ID" ]]; then
    SESSION_FILE="$HOME/.claude/current-session-id"
    if [[ -f "$SESSION_FILE" ]]; then
        SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null || echo "")
    fi
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="session-$(date +%Y%m%d-%H%M%S)-$$"
        mkdir -p "$(dirname "$SESSION_FILE")"
        echo "$SESSION_ID" > "$SESSION_FILE" 2>/dev/null || true
    fi
fi

# --- Sensitive field redaction ---
# Replace values of sensitive keys with [REDACTED], then truncate to 500 chars.
TOOL_INPUT_REDACTED="$TOOL_INPUT_RAW"

# Redact JSON keys: api_key, token, password, Authorization
# Use sed to replace values of sensitive keys with [REDACTED]
for KEY in api_key token password Authorization; do
    TOOL_INPUT_REDACTED=$(echo "$TOOL_INPUT_REDACTED" | \
        sed -E "s/\"${KEY}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"${KEY}\":\"[REDACTED]\"/g" \
        2>/dev/null || echo "$TOOL_INPUT_REDACTED")
done

# Truncate to first 500 chars for summary
TOOL_INPUT_SUMMARY=$(echo "$TOOL_INPUT_REDACTED" | head -c 500)

# --- Build timestamps ---
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Seconds-precision epoch in ms (avoids python3 process spawn overhead).
# Second-level precision is sufficient for pattern analysis; post-hoc pairing
# uses pre/post entries by tool_name proximity, not sub-second timing.
EPOCH_MS="$(date +%s)000"

# --- Ensure log directory exists ---
LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/tool-use-$(date +%Y-%m-%d).jsonl"

# --- Build and append JSONL entry (compact single-line output) ---
if [[ "$MODE" == "post" && -n "$EXIT_STATUS" ]]; then
    ENTRY=$(json_build \
        ts="$TS" \
        epoch_ms:n="$EPOCH_MS" \
        session_id="$SESSION_ID" \
        tool_name="$TOOL_NAME" \
        hook_type="$MODE" \
        tool_input_summary="$TOOL_INPUT_SUMMARY" \
        exit_status:n="$EXIT_STATUS" \
    )
else
    ENTRY=$(json_build \
        ts="$TS" \
        epoch_ms:n="$EPOCH_MS" \
        session_id="$SESSION_ID" \
        tool_name="$TOOL_NAME" \
        hook_type="$MODE" \
        tool_input_summary="$TOOL_INPUT_SUMMARY" \
    )
fi

if [[ -n "$ENTRY" ]]; then
    echo "$ENTRY" >> "$LOG_FILE" 2>/dev/null || true
fi

# This hook never intentionally writes to stdout. In post mode, the EXIT trap
# emits "{}" per bug #10463 workaround. _HOOK_HAS_OUTPUT is intentionally
# never set since this is a logging-only hook with no agent-visible output.
exit 0
