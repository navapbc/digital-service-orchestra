#!/usr/bin/env bash
# lockpick-workflow/hooks/bug-close-guard.sh
# PreToolUse hook (Bash matcher): enforces --reason flag on bug ticket closes.
#
# Replaces hookify rules: require-bug-close-reason, block-investigation-only-bug-close
#
# Logic:
#   1. Only fires on `tk close` commands
#   2. Looks up the ticket file and checks if type == bug
#   3. Non-bug tickets: always allowed (exit 0)
#   4. Bug tickets without --reason: BLOCKED (exit 2)
#   5. Bug tickets with investigation-only reason (no escalation): WARNING (exit 0 + stderr)

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"bug-close-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Only act on `tk close` commands
if ! [[ "$COMMAND" =~ tk[[:space:]]+close[[:space:]]+([^[:space:]]+) ]]; then
    exit 0
fi
TICKET_ID="${BASH_REMATCH[1]}"

# Find ticket file
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

TICKET_FILE=""
# Primary lookup: exact match
if [[ -f "$REPO_ROOT/.tickets/${TICKET_ID}.md" ]]; then
    TICKET_FILE="$REPO_ROOT/.tickets/${TICKET_ID}.md"
else
    # Fallback: find by suffix (excluding child tickets like id.1.md)
    TICKET_FILE=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name "*${TICKET_ID}.md" ! -name "*${TICKET_ID}.*.*" 2>/dev/null | head -1)
fi

# Ticket not found — fail open
if [[ -z "$TICKET_FILE" ]] || [[ ! -f "$TICKET_FILE" ]]; then
    exit 0
fi

# Read type from frontmatter (first 10 lines)
TICKET_TYPE=$(head -10 "$TICKET_FILE" | grep -m1 '^type:' | sed 's/^type:[[:space:]]*//' | tr -d '[:space:]')

# Non-bug tickets are always allowed
if [[ "$TICKET_TYPE" != "bug" ]]; then
    exit 0
fi

# Bug ticket — require --reason flag
if [[ "$COMMAND" != *"--reason"* ]]; then
    echo "BLOCKED [bug-close-guard]: Bug tickets require --reason flag." >&2
    echo "Add --reason=\"Fixed: <description>\" or --reason=\"Escalated to user: <findings>\"" >&2
    exit 2
fi

# Check for investigation-only language without escalation phrases
INVESTIGATION_PATTERN='(Investigated|investigated|code path|works correctly|no fix needed|correct behavior|feature works correctly|no code change)'
ESCALATION_PATTERN='([Ee]scalat|[Uu]ser confirmed|[Uu]ser decision|[Uu]ser approved|[Bb]y design|[Ww]orks as designed)'

if [[ "$COMMAND" =~ $INVESTIGATION_PATTERN ]] && ! [[ "$COMMAND" =~ $ESCALATION_PATTERN ]]; then
    echo "WARNING [bug-close-guard]: Reason looks like investigation findings, not a fix." >&2
    echo "Consider using --reason=\"Escalated to user: <findings>\" instead." >&2
    # Warning only — exit 0 to allow (user may have confirmed in conversation)
    exit 0
fi

exit 0
