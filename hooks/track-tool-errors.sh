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
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"track-tool-errors.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# This hook is non-blocking (error tracking only) — skip entirely without python3
check_tool python3 || exit 0

COUNTER_FILE="$HOME/.claude/tool-error-counter.json"
THRESHOLD=50

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
    echo '{"index":{},"errors":[],"bugs_created":{}}' > "$COUNTER_FILE"
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
COUNTER_DATA=$(cat "$COUNTER_FILE" 2>/dev/null || echo '{"index":{},"errors":[],"bugs_created":{}}')

# Guard against malformed JSON or missing .errors field before mutation
_VALID=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'errors' in d" <<< "$COUNTER_DATA" 2>/dev/null && echo "ok" || echo "bad")
if [[ "$_VALID" != "ok" ]]; then
    COUNTER_DATA='{"index":{},"errors":[],"bugs_created":{}}'
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

# --- Check threshold and notify ---
CURRENT_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('index',{}).get(sys.argv[1],0))" "$CATEGORY" <<< "$COUNTER_DATA" 2>/dev/null || echo 0)

# Categories that are normal operational noise — track counts but suppress notifications
NOISE_CATEGORIES="file_not_found command_exit_nonzero"
IS_NOISE=false
for nc in $NOISE_CATEGORIES; do
    if [[ "$CATEGORY" == "$nc" ]]; then IS_NOISE=true; break; fi
done

if [[ "$IS_NOISE" == "true" ]]; then
    exit 0
fi

# Notify at threshold and each subsequent multiple to avoid spamming
if [[ "$CURRENT_COUNT" -ge "$THRESHOLD" ]] && (( CURRENT_COUNT % THRESHOLD == 0 )); then
    # Check if a bug has already been created for this category at this threshold
    _ALREADY_BUGGED=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
cat=sys.argv[1]
cnt=int(sys.argv[2])
bugs=d.get('bugs_created',{})
# Check if already reported at this threshold level
key=cat
if key in bugs:
    print('yes')
else:
    print('no')
" "$CATEGORY" "$CURRENT_COUNT" <<< "$COUNTER_DATA" 2>/dev/null || echo "no")

    if [[ "$_ALREADY_BUGGED" != "yes" ]]; then
        # Create a bug ticket via tk
        _BUG_ID=""
        if command -v tk >/dev/null 2>&1; then
            _BUG_ID=$(tk create "Recurring tool error: $CATEGORY ($CURRENT_COUNT occurrences)" -t bug -p 2 2>/dev/null | grep -oE '[a-z]+-[0-9]+' | head -1 || echo "")
        fi

        # Record in bugs_created to avoid duplicate tickets
        COUNTER_DATA=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
cat=sys.argv[1]
bug_id=sys.argv[2] if len(sys.argv) > 2 else 'created'
d.setdefault('bugs_created',{})[cat] = bug_id if bug_id else 'created'
print(json.dumps(d))
" "$CATEGORY" "${_BUG_ID:-created}" <<< "$COUNTER_DATA" 2>/dev/null || echo "$COUNTER_DATA")
        echo "$COUNTER_DATA" > "$COUNTER_FILE"

        # Notify via hook output (becomes a system reminder)
        _HOOK_HAS_OUTPUT=1
        echo "Recurring tool error detected: '$CATEGORY' has occurred $CURRENT_COUNT times. Bug ticket created. Review: $COUNTER_FILE"
    fi
fi

exit 0
