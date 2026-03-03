#!/usr/bin/env bash
# lockpick-workflow/hooks/closed-parent-guard.sh
# PreToolUse hook (Bash matcher): blocks creating or associating children on closed tickets.
#
# Triggers on:
#   1. `tk create ... --parent <id>` — blocks if the parent ticket is closed
#   2. `tk dep <child-id> <parent-id>` — blocks if the target parent is closed
#
# Exit codes:
#   0 — allow the tool call
#   2 — block the tool call (parent is closed)

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"closed-parent-guard.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

INPUT=$(cat)

TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Detect the parent ticket ID from either pattern:
#   tk create "..." --parent <id>
#   tk dep <child-id> <parent-id>
PARENT_ID=""

if [[ "$COMMAND" =~ tk[[:space:]]+create[[:space:]].*--parent[[:space:]]+([^[:space:]]+) ]]; then
    PARENT_ID="${BASH_REMATCH[1]}"
elif [[ "$COMMAND" =~ tk[[:space:]]+dep[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
    # For `tk dep <child-id> <parent-id>`, the second argument is the parent
    PARENT_ID="${BASH_REMATCH[2]}"
fi

if [[ -z "$PARENT_ID" ]]; then
    exit 0
fi

# Locate the repo root to find .tickets/
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    exit 0
fi

# Find the ticket file
TICKET_FILE=""
if [[ -f "$REPO_ROOT/.tickets/${PARENT_ID}.md" ]]; then
    TICKET_FILE="$REPO_ROOT/.tickets/${PARENT_ID}.md"
else
    TICKET_FILE=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name "*${PARENT_ID}.md" ! -name "*${PARENT_ID}.*.*" 2>/dev/null | head -1)
fi

# Ticket not found — fail open (don't block on missing data)
if [[ -z "$TICKET_FILE" ]] || [[ ! -f "$TICKET_FILE" ]]; then
    exit 0
fi

# Read status from frontmatter using awk (scoped to the first --- block only)
TICKET_STATUS=$(awk '/^---$/{n++; next} n==1{print}' "$TICKET_FILE" | grep -m1 '^status:' | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')

if [[ "$TICKET_STATUS" == "closed" ]]; then
    echo "BLOCKED [closed-parent-guard]: Cannot create/associate children on closed ticket ${PARENT_ID}. Re-open the parent first with: tk status ${PARENT_ID} open" >&2
    exit 2
fi

exit 0
