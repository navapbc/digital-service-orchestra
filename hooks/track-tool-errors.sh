#!/usr/bin/env bash
# .claude/hooks/track-tool-errors.sh
# PostToolUseFailure hook: track, categorize, and count tool use errors
#
# On every tool failure:
#   1. Categorizes the error via pattern matching
#   2. Appends a detail entry to the error counter JSON
#   3. Increments the category count in the index
#   4. Creates a beads bug if any category reaches 50 occurrences
#
# Counter file: ~/.claude/tool-error-counter.json
# Template: .claude/docs/TOOL-ERROR-TEMPLATE.md

# DEFENSE-IN-DEPTH: Guarantee exit 0, suppress stderr, and always produce output.
# Claude Code bug #10463: 0-byte stdout is treated as "hook error" even with exit 0.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
exec 2>/dev/null

# Log unexpected errors to JSONL
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"track-tool-errors.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# This hook is non-blocking (error tracking only) — skip entirely without jq
check_tool jq || exit 0

COUNTER_FILE="$HOME/.claude/tool-error-counter.json"
THRESHOLD=50

# --- Read hook input ---
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
ERROR_MSG=$(echo "$INPUT" | jq -r '.error // empty' 2>/dev/null || echo "")
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
IS_INTERRUPT=$(echo "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null || echo "false")

# Skip user interrupts (not real errors)
if [[ "$IS_INTERRUPT" == "true" ]]; then
    exit 0
fi

# Skip if no error message
if [[ -z "$ERROR_MSG" ]]; then
    exit 0
fi

# --- Initialize counter file if missing ---
if [[ ! -f "$COUNTER_FILE" ]]; then
    echo '{"index":{},"errors":[],"bugs_created":{}}' > "$COUNTER_FILE"
fi

# --- Categorize the error via pattern matching ---
CATEGORY=""
INPUT_SUMMARY=""

ERROR_LOWER=$(echo "$ERROR_MSG" | tr '[:upper:]' '[:lower:]')
if echo "$ERROR_LOWER" | grep -q "file not found\|no such file"; then
    CATEGORY="file_not_found"
elif echo "$ERROR_LOWER" | grep -q "permission denied"; then
    CATEGORY="permission_denied"
elif echo "$ERROR_LOWER" | grep -q "command not found"; then
    CATEGORY="command_not_found"
elif echo "$ERROR_LOWER" | grep -q "old_string.*not unique\|not found uniquely\|is not unique in the file"; then
    CATEGORY="edit_string_not_unique"
elif echo "$ERROR_LOWER" | grep -q "not found"; then
    CATEGORY="edit_string_not_found"
elif echo "$ERROR_LOWER" | grep -q "timed out\|timedout\|deadline exceeded\|timeout exceeded"; then
    CATEGORY="timeout"
elif echo "$ERROR_LOWER" | grep -q "failed.*passed\|passed.*failed\|pytest\|test session starts"; then
    CATEGORY="test_failure"
elif echo "$ERROR_LOWER" | grep -q "ruff\|mypy\|format-check"; then
    CATEGORY="lint_failure"
elif echo "$ERROR_LOWER" | grep -q "syntax error"; then
    CATEGORY="syntax_error"
elif echo "$ERROR_LOWER" | grep -q "non-zero\|exit code"; then
    CATEGORY="command_exit_nonzero"
else
    # Generic: tool_name + first 3 words of error
    CATEGORY=$(echo "${TOOL_NAME}_${ERROR_MSG}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '_' | sed 's/__*/_/g' | cut -d_ -f1-4 | head -c 50)
fi
INPUT_SUMMARY="$TOOL_NAME: $(echo "$TOOL_INPUT" | jq -r 'to_entries | map(.key + "=" + (.value | tostring | .[0:80])) | join(", ")' 2>/dev/null | head -c 120)"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Update counter file ---
COUNTER_DATA=$(cat "$COUNTER_FILE" 2>/dev/null || echo '{"index":{},"errors":[],"bugs_created":{}}')

NEXT_ID=$(echo "$COUNTER_DATA" | jq '.errors | length + 1')

# Append error detail
COUNTER_DATA=$(echo "$COUNTER_DATA" | jq \
    --arg cat "$CATEGORY" \
    --arg tool "$TOOL_NAME" \
    --arg summary "$INPUT_SUMMARY" \
    --arg error "$ERROR_MSG" \
    --arg session "$SESSION_ID" \
    --arg ts "$TIMESTAMP" \
    --argjson id "$NEXT_ID" \
    '.errors += [{
        "id": $id,
        "timestamp": $ts,
        "category": $cat,
        "tool_name": $tool,
        "input_summary": $summary,
        "error_message": $error,
        "session_id": $session
    }]')

# Increment index count
COUNTER_DATA=$(echo "$COUNTER_DATA" | jq \
    --arg cat "$CATEGORY" \
    '.index[$cat] = ((.index[$cat] // 0) + 1)')

echo "$COUNTER_DATA" > "$COUNTER_FILE"

# --- Check threshold and create bug if needed ---
CURRENT_COUNT=$(echo "$COUNTER_DATA" | jq --arg cat "$CATEGORY" '.index[$cat] // 0')
BUG_EXISTS=$(echo "$COUNTER_DATA" | jq -r --arg cat "$CATEGORY" '.bugs_created[$cat] // "none"')

if [[ "$CURRENT_COUNT" -ge "$THRESHOLD" && "$BUG_EXISTS" == "none" ]]; then
    BUG_ID=""
    if command -v bd &>/dev/null; then
        # Create a beads bug for the recurring error
        BD_OUTPUT=$(bd create \
            --title="Investigate recurring tool error: $CATEGORY ($CURRENT_COUNT occurrences)" \
            --type=bug --priority=2 \
            --description="The '$CATEGORY' tool error has been observed $CURRENT_COUNT times across sessions. Recent example: $TOOL_NAME failed with: $ERROR_MSG. Review full log: $COUNTER_FILE" \
            2>&1 || echo "")
        BUG_ID=$(echo "$BD_OUTPUT" | sed -n 's/.*Created issue: \([^ ]*\).*/\1/p' | head -1)
    fi

    if [[ -n "$BUG_ID" ]]; then
        # Record bug ID to prevent duplicates
        COUNTER_DATA=$(cat "$COUNTER_FILE")
        COUNTER_DATA=$(echo "$COUNTER_DATA" | jq \
            --arg cat "$CATEGORY" \
            --arg bug "$BUG_ID" \
            '.bugs_created[$cat] = $bug')
        echo "$COUNTER_DATA" > "$COUNTER_FILE"
    fi

    # Notify via hook output (becomes a system reminder)
    _HOOK_HAS_OUTPUT=1
    echo "Recurring tool error detected: '$CATEGORY' has occurred $CURRENT_COUNT times (threshold: $THRESHOLD)."
    if [[ -n "$BUG_ID" ]]; then
        echo "Bug created: $BUG_ID — investigate root cause before continuing."
    else
        echo "Failed to create bug automatically. Create one manually:"
        echo "  bd q \"Investigate recurring tool error: $CATEGORY\" -t bug -p 2"
    fi
fi

exit 0
