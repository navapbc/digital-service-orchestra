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

# This hook is non-blocking (logging only) — skip entirely without jq
check_tool jq || exit 0

# Fast path: exit immediately if logging is not enabled
test -f "$HOME/.claude/tool-logging-enabled" || exit 0

# --- Read hook input ---
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
TOOL_INPUT_RAW=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
# PostToolUse only fires on success; exit code is not at top level.
# For Bash, read from tool_response if available (for richer logging).
EXIT_STATUS=""
if [[ "$MODE" == "post" ]]; then
    EXIT_STATUS=$(echo "$INPUT" | jq -r '.tool_response.exit_code // empty' 2>/dev/null || echo "")
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
for KEY in api_key token password Authorization; do
    TOOL_INPUT_REDACTED=$(echo "$TOOL_INPUT_REDACTED" | \
        jq -c --arg k "$KEY" 'if type == "object" and has($k) then .[$k] = "[REDACTED]" else . end' \
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
    ENTRY=$(jq -nc \
        --arg ts "$TS" \
        --argjson epoch_ms "$EPOCH_MS" \
        --arg session_id "$SESSION_ID" \
        --arg tool_name "$TOOL_NAME" \
        --arg hook_type "$MODE" \
        --arg tool_input_summary "$TOOL_INPUT_SUMMARY" \
        --argjson exit_status "$EXIT_STATUS" \
        '{
            ts: $ts,
            epoch_ms: $epoch_ms,
            session_id: $session_id,
            tool_name: $tool_name,
            hook_type: $hook_type,
            tool_input_summary: $tool_input_summary,
            exit_status: $exit_status
        }' 2>/dev/null || echo "")
else
    ENTRY=$(jq -nc \
        --arg ts "$TS" \
        --argjson epoch_ms "$EPOCH_MS" \
        --arg session_id "$SESSION_ID" \
        --arg tool_name "$TOOL_NAME" \
        --arg hook_type "$MODE" \
        --arg tool_input_summary "$TOOL_INPUT_SUMMARY" \
        '{
            ts: $ts,
            epoch_ms: $epoch_ms,
            session_id: $session_id,
            tool_name: $tool_name,
            hook_type: $hook_type,
            tool_input_summary: $tool_input_summary
        }' 2>/dev/null || echo "")
fi

if [[ -n "$ENTRY" ]]; then
    echo "$ENTRY" >> "$LOG_FILE" 2>/dev/null || true
fi

# This hook never intentionally writes to stdout. In post mode, the EXIT trap
# emits "{}" per bug #10463 workaround. _HOOK_HAS_OUTPUT is intentionally
# never set since this is a logging-only hook with no agent-visible output.
exit 0
