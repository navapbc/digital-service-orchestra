#!/usr/bin/env bash
# hooks/taskoutput-block-guard.sh
# PreToolUse hook: block TaskOutput calls with block=false
#
# Addresses ticket issue lxjiu:
#   TaskOutput with block=false is not supported by the Claude Code tool API
#   and causes errors or silent failures. Agents must always use block=true
#   (the default) or omit the block parameter entirely.
#
# How it works:
#   - Reads the TaskOutput tool input
#   - If block=false (or "false"), blocks with an explanation
#   - Otherwise allows (block=true, or not specified)

HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"taskoutput-block-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

# Parse block field — must handle both boolean false and string "false".
# Uses grep on raw JSON to detect block value without jq dependency.
BLOCK_VALUE=""
if echo "$INPUT" | grep -qE '"block"\s*:\s*false'; then
    BLOCK_VALUE="false"
elif echo "$INPUT" | grep -qE '"block"\s*:\s*true'; then
    BLOCK_VALUE="true"
fi

# Allow if block is not specified, true, or anything other than false
if [[ "$BLOCK_VALUE" != "false" ]]; then
    exit 0
fi

echo "BLOCKED: TaskOutput with block=false is not supported." >&2
echo "" >&2
echo "The TaskOutput tool API does not support non-blocking (block=false) operation." >&2
echo "Using block=false causes errors or silent failures." >&2
echo "" >&2
echo "Fix: Remove the block parameter (defaults to true) or set block=true." >&2
echo "To check on a background task, use block=true with a short timeout instead." >&2
exit 2
