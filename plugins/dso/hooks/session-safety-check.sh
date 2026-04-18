#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# .claude/hooks/session-safety-check.sh
# SessionStart hook: analyze hook error log and warn about recurring errors
#
# Reads ~/.claude/logs/dso-hook-errors.jsonl (new canonical path) AND
# ~/.claude/hook-error-log.jsonl (legacy path, migration window).
# Counts errors per hook in the last 24h, deduplicating across both paths.
# If any hook exceeds the threshold, outputs a warning.

# Source shared ERR handler library (fail-open: skip if unavailable)
if [[ -f "${_PLUGIN_ROOT}/hooks/lib/hook-error-handler.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_PLUGIN_ROOT}/hooks/lib/hook-error-handler.sh" 2>/dev/null || true
    _dso_register_hook_err_handler "session-safety-check.sh"
fi

# Never surface errors to user — log and exit cleanly
# New canonical log path (used by hook-error-handler.sh)
HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
# Legacy log path (kept for migration window dual-read)
HOOK_ERROR_LOG_LEGACY="$HOME/.claude/hook-error-log.jsonl"

THRESHOLD=10

# --- No log files? Nothing to analyze. ---
if [[ ! -f "$HOOK_ERROR_LOG" && ! -f "$HOOK_ERROR_LOG_LEGACY" ]]; then
    exit 0
fi

# --- Rotate: remove entries older than 7 days from new canonical log ---
if [[ "$(uname)" == "Darwin" ]]; then
    ROTATE_CUTOFF=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
else
    ROTATE_CUTOFF=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
fi
# Rotate a single log file: remove entries older than ROTATE_CUTOFF
_rotate_log() {
    local _log_path="$1"
    [[ -n "$ROTATE_CUTOFF" && -f "$_log_path" ]] || return 0
    local _rotated
    _rotated=$(python3 -c "
import sys, json
cutoff = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        ts = obj.get('ts', '')
        if ts and str(ts) >= cutoff:
            print(line)
    except (json.JSONDecodeError, KeyError):
        pass
" "$ROTATE_CUTOFF" < "$_log_path" 2>/dev/null) || _rotated=""
    if [[ -n "$_rotated" ]]; then
        echo "$_rotated" > "$_log_path.tmp" && mv "$_log_path.tmp" "$_log_path"
    else
        : > "$_log_path"
    fi
}

# Rotate both the new canonical log and the legacy log
_rotate_log "$HOOK_ERROR_LOG"
_rotate_log "$HOOK_ERROR_LOG_LEGACY"

# --- Get 24h-ago timestamp for filtering ---
if [[ "$(uname)" == "Darwin" ]]; then
    CUTOFF=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
else
    CUTOFF=$(date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
fi

if [[ -z "$CUTOFF" ]]; then
    exit 0
fi

# --- Count errors per hook in the last 24h (dual-read) ---
# Collect entries from both new canonical and legacy log paths.
# Both paths are read sequentially; each line in each file is an independent
# error event. Entries in one path do not suppress entries in the other path,
# since writes to the two paths come from different tools (old inline trap vs.
# the new hook-error-handler.sh library).
COUNTS=$(python3 -c "
import sys, json

cutoff = sys.argv[1]
paths = sys.argv[2:]

hooks = []

for path in paths:
    try:
        with open(path, 'r') as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    obj = json.loads(raw_line)
                    ts = obj.get('ts', '')
                    hook = obj.get('hook', '')
                    if ts and hook and str(ts) >= cutoff:
                        hooks.append(hook)
                except (json.JSONDecodeError, KeyError):
                    pass
    except (OSError, IOError):
        pass

for h in sorted(hooks):
    print(h)
" "$CUTOFF" \
    "${HOOK_ERROR_LOG}" \
    "${HOOK_ERROR_LOG_LEGACY}" \
    2>/dev/null | sort | uniq -c | sort -rn || echo "")

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
    echo "Review: ~/.claude/logs/dso-hook-errors.jsonl"
fi

exit 0
