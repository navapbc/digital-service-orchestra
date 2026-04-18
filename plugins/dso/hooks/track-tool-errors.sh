#!/usr/bin/env bash
# .claude/hooks/track-tool-errors.sh
# PostToolUseFailure hook: track, categorize, and count tool use errors
#
# On every tool failure:
#   1. Categorizes the error via pattern matching
#   2. Appends a detail entry to the error counter JSON
#   3. Increments the category count in the index
#
# Counter file: ~/.claude/tool-error-counter.json
# Template: .claude/docs/TOOL-ERROR-TEMPLATE.md

# DEFENSE-IN-DEPTH: Guarantee exit 0, suppress stderr, and always produce output.
# Claude Code bug #10463: 0-byte stdout is treated as "hook error" even with exit 0.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
exec 2>/dev/null

# Log unexpected errors to JSONL
HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"track-tool-errors.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PATH-ANCHOR: HOOK_DIR is anchored to ${CLAUDE_PLUGIN_ROOT}/hooks/ (this file's directory).
# read-config.sh is one level up in ${_PLUGIN_ROOT}/scripts/, so the correct path
# is $HOOK_DIR/../scripts/read-config.sh (one "..").
# If this hook were sourced from hooks/lib/ instead, the depth would be two ".."
# ($HOOK_LIB_DIR/../../scripts/read-config.sh). The 2>/dev/null || echo 'false'
# guard silently suppresses path errors — always verify depth with:
#   ls "$(dirname "${BASH_SOURCE[0]}")/../scripts/read-config.sh"
_MONITORING=$(bash "$HOOK_DIR/../scripts/read-config.sh" monitoring.tool_errors 2>/dev/null || echo "false")
[[ "$_MONITORING" != "true" ]] && exit 0
source "$HOOK_DIR/lib/deps.sh"

# This hook is non-blocking (error tracking only) — skip entirely without python3
check_tool python3 || exit 0

COUNTER_FILE="$HOME/.claude/tool-error-counter.json"

# --- Read hook input ---
INPUT=$(cat)

TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
ERROR_MSG=$(parse_json_field "$INPUT" '.error')
TOOL_INPUT=$(parse_json_object "$INPUT" '.tool_input')
[[ -z "$TOOL_INPUT" ]] && TOOL_INPUT="{}"
SESSION_ID=$(parse_json_field "$INPUT" '.session_id')
IS_INTERRUPT=$(parse_json_field "$INPUT" '.is_interrupt')
[[ -z "$IS_INTERRUPT" ]] && IS_INTERRUPT="false"

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
    echo '{"index":{},"errors":[]}' > "$COUNTER_FILE"
fi

# --- Categorize the error via pattern matching ---
CATEGORY=""
INPUT_SUMMARY=""

ERROR_LOWER=$(echo "$ERROR_MSG" | tr '[:upper:]' '[:lower:]')
if echo "$ERROR_LOWER" | grep -qE "file not found|no such file"; then
    CATEGORY="file_not_found"
elif echo "$ERROR_LOWER" | grep -q "permission denied"; then
    CATEGORY="permission_denied"
elif echo "$ERROR_LOWER" | grep -q "command not found"; then
    CATEGORY="command_not_found"
elif echo "$ERROR_LOWER" | grep -qE "old_string.*not unique|not found uniquely|is not unique in the file"; then
    CATEGORY="edit_string_not_unique"
elif echo "$ERROR_LOWER" | grep -q "not found"; then
    CATEGORY="edit_string_not_found"
elif echo "$ERROR_LOWER" | grep -qE "timed out|timedout|deadline exceeded|timeout exceeded"; then
    CATEGORY="timeout"
elif echo "$ERROR_LOWER" | grep -qE "failed.*passed|passed.*failed|pytest|test session starts"; then
    CATEGORY="test_failure"
elif echo "$ERROR_LOWER" | grep -qE "ruff|mypy|format-check"; then
    CATEGORY="lint_failure"
elif echo "$ERROR_LOWER" | grep -q "syntax error"; then
    CATEGORY="syntax_error"
elif echo "$ERROR_LOWER" | grep -qE "lock.*blocked|blocked.*lock"; then
    CATEGORY="lock_blocked"
elif echo "$ERROR_LOWER" | grep -qE "validate.*issues|issues.*valid"; then
    CATEGORY="validate_issues_warning"
elif echo "$ERROR_LOWER" | grep -qE "non-zero|exit code"; then
    CATEGORY="command_exit_nonzero"
else
    # Generic: tool_name + first 3 words of error
    CATEGORY=$(echo "${TOOL_NAME}_${ERROR_MSG}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '_' | sed 's/__*/_/g' | cut -d_ -f1-4 | head -c 50)
fi
INPUT_SUMMARY="$TOOL_NAME: $(json_summarize_input "$TOOL_INPUT" 2>/dev/null | head -c 120)"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Update counter file ---
COUNTER_DATA=$(cat "$COUNTER_FILE" 2>/dev/null || echo '{"index":{},"errors":[]}')

# Guard against malformed JSON or missing .errors field before mutation
_VALID=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'errors' in d" <<< "$COUNTER_DATA" 2>/dev/null && echo "ok" || echo "bad")
if [[ "$_VALID" != "ok" ]]; then
    COUNTER_DATA='{"index":{},"errors":[]}'
fi

# Append error detail and increment index count in a single python3 call
COUNTER_DATA=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
cat = sys.argv[1]
tool = sys.argv[2]
summary = sys.argv[3]
error = sys.argv[4]
session = sys.argv[5]
ts = sys.argv[6]
next_id = len(data.get('errors', [])) + 1
data.setdefault('errors', []).append({
    'id': next_id,
    'timestamp': ts,
    'category': cat,
    'tool_name': tool,
    'input_summary': summary,
    'error_message': error,
    'session_id': session
})
data.setdefault('index', {})[cat] = data['index'].get(cat, 0) + 1
print(json.dumps(data))
" "$CATEGORY" "$TOOL_NAME" "$INPUT_SUMMARY" "$ERROR_MSG" "$SESSION_ID" "$TIMESTAMP" <<< "$COUNTER_DATA")

echo "$COUNTER_DATA" > "$COUNTER_FILE"

# Categories that are normal operational noise — track counts but suppress notifications
NOISE_CATEGORIES="file_not_found command_exit_nonzero"
IS_NOISE=false
for nc in $NOISE_CATEGORIES; do
    if [[ "$CATEGORY" == "$nc" ]]; then IS_NOISE=true; break; fi
done

if [[ "$IS_NOISE" == "true" ]]; then
    exit 0
fi

exit 0
