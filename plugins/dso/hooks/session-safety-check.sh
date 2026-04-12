#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# .claude/hooks/session-safety-check.sh
# SessionStart hook: analyze hook error log and warn about recurring errors
#
# Reads ~/.claude/hook-error-log.jsonl, counts errors per hook in the last 24h.
# If any hook exceeds the threshold, outputs a warning.

# Never surface errors to user — log and exit cleanly
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"session-safety-check.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

THRESHOLD=10

# --- No log file? Nothing to analyze. ---
if [[ ! -f "$HOOK_ERROR_LOG" ]]; then
    exit 0
fi

# --- Rotate: remove entries older than 7 days ---
if [[ "$(uname)" == "Darwin" ]]; then
    ROTATE_CUTOFF=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
else
    ROTATE_CUTOFF=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
fi
if [[ -n "$ROTATE_CUTOFF" ]]; then
    ROTATED=$(python3 -c "
import sys, json
cutoff = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        ts = obj.get('ts', '')
        if ts and ts >= cutoff:
            print(line)
    except (json.JSONDecodeError, KeyError):
        pass
" "$ROTATE_CUTOFF" < "$HOOK_ERROR_LOG" 2>/dev/null) || ROTATED=""
    if [[ -n "$ROTATED" ]]; then
        echo "$ROTATED" > "$HOOK_ERROR_LOG.tmp" && mv "$HOOK_ERROR_LOG.tmp" "$HOOK_ERROR_LOG"
    else
        : > "$HOOK_ERROR_LOG"
    fi
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
# Use python3 to filter JSONL by timestamp and extract hook names
COUNTS=$(python3 -c "
import sys, json
cutoff = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        ts = obj.get('ts', '')
        hook = obj.get('hook', '')
        if ts and ts >= cutoff and hook:
            print(hook)
    except (json.JSONDecodeError, KeyError):
        pass
" "$CUTOFF" < "$HOOK_ERROR_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "")

if [[ -z "$COUNTS" ]]; then
    exit 0
fi

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
        # Skip phantom hooks — only create bugs for hooks that exist
        HOOK_EXISTS=false
        _REPO_ROOT_SS="$(git rev-parse --show-toplevel 2>/dev/null)"
        for _HOOK_DIR in "$HOME/.claude/hooks" \
                         "$_REPO_ROOT_SS/hooks" \
                         "${_PLUGIN_ROOT}/hooks"; do
            if [[ -f "$_HOOK_DIR/$HOOK_NAME" ]]; then
                HOOK_EXISTS=true
                break
            fi
        done
        if [[ "$HOOK_EXISTS" == "false" ]]; then
            continue
        fi

        WARNINGS="${WARNINGS}\n  - ${HOOK_NAME}: ${COUNT} errors in last 24h"
    fi
done <<< "$COUNTS"

# --- Check for unreviewed checkpoint commits ---
# If .checkpoint-needs-review exists in HEAD, a pre-compact auto-save
# committed with --no-verify and needs review before new work.
REPO_ROOT_CHECK=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -n "$REPO_ROOT_CHECK" && -f "$REPO_ROOT_CHECK/.checkpoint-needs-review" ]]; then
    echo "# Unreviewed Checkpoint Detected"
    echo ""
    echo "A pre-compaction auto-save committed code without review."
    echo "Run /dso:commit (which includes /dso:review) to review and clear the checkpoint before starting new work."
    echo ""
fi

# --- Output warnings if any ---
if [[ -n "$WARNINGS" ]]; then
    echo "# Hook Error Report"
    echo ""
    echo "The following hooks have exceeded the error threshold (${THRESHOLD}/24h):"
    echo -e "$WARNINGS"
    echo ""
    echo "Review: ~/.claude/hook-error-log.jsonl"
fi

exit 0
