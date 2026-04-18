#!/usr/bin/env bash
# hooks/title-length-validator.sh
# PreToolUse hook: blocks Write or Edit tool calls that would set a ticket
# title longer than 255 characters in a ticket event file (v3 ticket system).
#
# Jira's summary field has a 255-character limit. Enforcing this at write time
# prevents sync-time failures.
#
# Logic:
#   1. Only fires on Write or Edit tool calls
#   2. Inspects any file path (v3: no directory restriction)
#   3. For Write: scans the full 'content' field for a markdown title line (# ...)
#   4. For Edit: scans the 'new_string' field for a markdown title line
#   5. If a title line is found and its text exceeds 255 chars: BLOCKED (exit 2)
#   6. All other cases: exit 0 (fail open)
#
# Exit codes:
#   0 — allowed
#   2 — BLOCKED (title too long)

TITLE_MAX=255

HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"title-length-validator.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

# Only act on Write or Edit tool calls
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
    exit 0
fi

# Get the file path
FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Extract the text content to scan for a title line
# For Write: use 'content'; for Edit: use 'new_string'
if [[ "$TOOL_NAME" == "Write" ]]; then
    FIELD='.tool_input.content'
else
    FIELD='.tool_input.new_string'
fi

# Extract text content using bash-native parse_json_field (no jq dependency).
TEXT_CONTENT=""
TEXT_CONTENT=$(parse_json_field "$INPUT" "$FIELD")

if [[ -z "$TEXT_CONTENT" ]]; then
    exit 0
fi

# Find the first markdown H1 title line (# Title text)
# We process the content line by line (handling \n escape sequences if present)
# by normalizing escaped newlines first.
TITLE_LINE=""
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
    exit 0
fi

# Measure title length
TITLE_LEN=${#TITLE_LINE}

if (( TITLE_LEN > TITLE_MAX )); then
    echo "BLOCKED [title-length-validator]: Ticket title is ${TITLE_LEN} characters (max ${TITLE_MAX})." >&2
    echo "Jira's summary field has a ${TITLE_MAX}-character limit." >&2
    echo "Please shorten the title before saving: ${FILE_PATH}" >&2
    exit 2
fi

exit 0
