#!/usr/bin/env bash
# .claude/hooks/session-safety-check.sh
# SessionStart hook: analyze hook error log and create bugs for recurring errors
#
# Reads ~/.claude/hook-error-log.jsonl, counts errors per hook in the last 24h.
# If any hook exceeds the threshold, outputs a warning and creates a ticket bug.
# Deduplicates bugs via a "bugs_created" marker in the log directory.

# Never surface errors to user — log and exit cleanly
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"session-safety-check.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

THRESHOLD=10
BUGS_DIR="$HOME/.claude/hook-error-bugs"

# --- No log file? Nothing to analyze. ---
if [[ ! -f "$HOOK_ERROR_LOG" ]]; then
    exit 0
fi

# --- Ensure jq is available ---
if ! command -v jq &>/dev/null; then
    exit 0
fi

# --- Get 24h-ago timestamp for filtering ---
if [[ "$(uname)" == "Darwin" ]]; then
    CUTOFF=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
else
    CUTOFF=$(date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
fi

if [[ -z "$CUTOFF" ]]; then
    exit 0
fi

# --- Count errors per hook in the last 24h ---
# Use jq to filter by timestamp and count by hook name
COUNTS=$(jq -r --arg cutoff "$CUTOFF" '
    select(.ts != null and .ts >= $cutoff and .hook != null)
    | .hook
' "$HOOK_ERROR_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "")

if [[ -z "$COUNTS" ]]; then
    exit 0
fi

# --- Ensure bugs directory exists ---
mkdir -p "$BUGS_DIR" 2>/dev/null || exit 0

# --- Check each hook against threshold ---
WARNINGS=""
while IFS= read -r line; do
    COUNT=$(echo "$line" | awk '{print $1}')
    HOOK_NAME=$(echo "$line" | awk '{print $2}')

    if [[ -z "$COUNT" || -z "$HOOK_NAME" ]]; then
        continue
    fi

    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
        continue
    fi

    if (( COUNT >= THRESHOLD )); then
        WARNINGS="${WARNINGS}\n  - ${HOOK_NAME}: ${COUNT} errors in last 24h"

        # Create bug if not already created for this hook
        MARKER="$BUGS_DIR/${HOOK_NAME}.bug"
        if [[ ! -f "$MARKER" ]]; then
            if command -v tk &>/dev/null; then
                BUG_ID=$(tk create "Fix recurring hook errors: ${HOOK_NAME} (${COUNT} in 24h)" \
                    -t bug -p 2 \
                    -d "The hook '${HOOK_NAME}' has logged ${COUNT} errors in the last 24 hours (threshold: ${THRESHOLD}). Review ~/.claude/hook-error-log.jsonl for details. This bug was auto-created by session-safety-check.sh." \
                    2>/dev/null || echo '')
                if [[ -n "$BUG_ID" ]]; then
                    echo "$BUG_ID" > "$MARKER"
                fi
            fi
        fi
    fi
done <<< "$COUNTS"

# --- Output warnings if any ---
if [[ -n "$WARNINGS" ]]; then
    echo "# Hook Error Report"
    echo ""
    echo "The following hooks have exceeded the error threshold (${THRESHOLD}/24h):"
    echo -e "$WARNINGS"
    echo ""
    echo "Review: ~/.claude/hook-error-log.jsonl"
    echo "Bugs have been auto-created for investigation."
fi

exit 0
