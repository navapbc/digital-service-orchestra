#!/usr/bin/env bash
set -euo pipefail
# scripts/log-dispatch.sh
# Log a sub-agent dispatch for domain mismatch analysis.
#
# Called by sprint orchestrator (or manually) when dispatching a sub-agent.
# Appends a JSONL entry to ~/.claude/logs/dispatch-YYYY-MM-DD.jsonl.
#
# Usage:
#   log-dispatch.sh <session_id> <assigned_agent_type> [task_id]
#
# Example:
#   log-dispatch.sh "session-20260224-143022-12345" "mechanical_fix" "LOCK-42"
#
# The dispatch log is consumed by analyze-tool-use.py (Pattern 7: domain mismatch).

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $(basename "$0") <session_id> <assigned_agent_type> [task_id]" >&2
    exit 1
fi

SESSION_ID="$1"
ASSIGNED_AGENT="$2"
TASK_ID="${3:-}"

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/dispatch-$(date +%Y-%m-%d).jsonl"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Use jq if available for proper JSON escaping; fall back to printf
if command -v jq >/dev/null 2>&1; then
    ENTRY=$(jq -nc \
        --arg ts "$TS" \
        --arg session_id "$SESSION_ID" \
        --arg assigned_agent "$ASSIGNED_AGENT" \
        --arg task_id "$TASK_ID" \
        '{ts: $ts, session_id: $session_id, assigned_agent: $assigned_agent, task_id: $task_id}')
else
    # Fallback without jq: sanitize values to prevent malformed JSON.
    # Strip quotes/backslashes since these values come from orchestrator.
    # shellcheck disable=SC1003
    _sanitize() { printf '%s' "$1" | tr -d '"\\'; }
    ENTRY=$(printf '{"ts":"%s","session_id":"%s","assigned_agent":"%s","task_id":"%s"}' \
        "$(_sanitize "$TS")" "$(_sanitize "$SESSION_ID")" \
        "$(_sanitize "$ASSIGNED_AGENT")" "$(_sanitize "$TASK_ID")")
fi

echo "$ENTRY" >> "$LOG_FILE"
