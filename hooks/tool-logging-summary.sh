#!/usr/bin/env bash
# .claude/hooks/tool-logging-summary.sh
# Stop hook: output a session summary of tool usage from the JSONL tool-use log.
#
# Also performs 7-day log rotation.
#
# Reads: ~/.claude/logs/tool-use-YYYY-MM-DD.jsonl (filtered by current session_id)
# Outputs: markdown summary to stdout (becomes a system reminder)
#
# NOTE: Stop hooks do NOT receive stdin JSON. Session ID is read from the
#       file-based fallback: ~/.claude/current-session-id (written by tool-logging.sh).

# DEFENSE-IN-DEPTH: fail-open — never block or surface errors.
exec 2>/dev/null
trap 'exit 0' EXIT

# Source shared dependency library
# Note: Stop hooks don't receive stdin; HOOK_DIR must be resolved from script path
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# This hook uses python3 for JSONL processing — skip entirely without python3
check_tool python3 || exit 0

# Fast path: skip entirely if logging is not enabled
test -f "$HOME/.claude/tool-logging-enabled" || exit 0

# --- Read session ID from file-based fallback ---
SESSION_ID=$(cat "$HOME/.claude/current-session-id" 2>/dev/null || echo "")
if [[ -z "$SESSION_ID" ]]; then
    exit 0
fi

# --- Locate today's log file ---
LOG_FILE="$HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
if [[ ! -f "$LOG_FILE" ]]; then
    exit 0
fi

# --- Process all JSONL data in a single python3 invocation ---
# Reads the log file, filters by session_id, computes all summary stats,
# and outputs structured lines that bash parses for the markdown template.
SUMMARY_DATA=$(python3 -c "
import json, sys
from collections import Counter

session_id = sys.argv[1]
log_file = sys.argv[2]

entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if obj.get('session_id') == session_id:
            entries.append(obj)

if not entries:
    sys.exit(1)

# Count post entries
post_entries = [e for e in entries if e.get('hook_type') == 'post']
total_calls = len(post_entries)

if total_calls < 10:
    # Signal to bash: below threshold
    print('BELOW_THRESHOLD')
    sys.exit(0)

# Tool counts (sorted by count descending)
tool_counter = Counter(e.get('tool_name', 'unknown') for e in post_entries)
tool_counts = sorted(tool_counter.items(), key=lambda x: (-x[1], x[0]))

# Duration from all entries
all_epochs = sorted(e.get('epoch_ms', 0) for e in entries if e.get('epoch_ms'))
first_epoch = all_epochs[0] if all_epochs else 0
last_epoch = all_epochs[-1] if all_epochs else 0
duration_secs = max(0, (last_epoch - first_epoch) // 1000) if last_epoch > first_epoch else 0

# Top 5 slowest calls: pair pre/post by tool_name + time proximity
pre_entries = [e for e in entries if e.get('hook_type') == 'pre']
# For each post entry, find the closest preceding pre with same tool_name
slow_calls = []
for p in post_entries:
    tool = p.get('tool_name', '')
    post_epoch = p.get('epoch_ms', 0)
    # Find all pre entries for this tool with epoch <= post_epoch
    candidates = [
        pr for pr in pre_entries
        if pr.get('tool_name') == tool and pr.get('epoch_ms', 0) <= post_epoch
    ]
    if candidates:
        # Pick the one with the largest epoch (closest preceding)
        best = max(candidates, key=lambda x: x.get('epoch_ms', 0))
        delta_ms = post_epoch - best.get('epoch_ms', 0)
        slow_calls.append((tool, delta_ms))

slow_calls.sort(key=lambda x: -x[1])
slow_calls = slow_calls[:5]

# Output structured data
print('TOTAL_CALLS={}'.format(total_calls))
print('DURATION_SECS={}'.format(duration_secs))
for tool, count in tool_counts:
    print('TOOL_COUNT={}:{}'.format(tool, count))
for tool, delta_ms in slow_calls:
    print('SLOW_CALL={}:{}'.format(tool, delta_ms // 1000))
print('DONE')
" "$SESSION_ID" "$LOG_FILE" 2>/dev/null || echo "")

if [[ -z "$SUMMARY_DATA" ]]; then
    exit 0
fi

# Check for below-threshold signal
if [[ "$SUMMARY_DATA" == "BELOW_THRESHOLD" ]]; then
    # --- Log rotation (always run regardless of threshold) ---
    find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true
    exit 0
fi

# --- Parse structured output ---
TOTAL_CALLS=""
DURATION_SECS=0
TOOL_COUNTS_LINES=""
SLOW_CALLS_LINES=""

while IFS= read -r line; do
    case "$line" in
        TOTAL_CALLS=*)
            TOTAL_CALLS="${line#TOTAL_CALLS=}"
            ;;
        DURATION_SECS=*)
            DURATION_SECS="${line#DURATION_SECS=}"
            ;;
        TOOL_COUNT=*)
            local_data="${line#TOOL_COUNT=}"
            tool="${local_data%%:*}"
            count="${local_data#*:}"
            TOOL_COUNTS_LINES="${TOOL_COUNTS_LINES}  - ${tool}: ${count}"$'\n'
            ;;
        SLOW_CALL=*)
            local_data="${line#SLOW_CALL=}"
            tool="${local_data%%:*}"
            secs="${local_data#*:}"
            SLOW_CALLS_LINES="${SLOW_CALLS_LINES}  - ${tool}: ${secs}s"$'\n'
            ;;
        DONE)
            break
            ;;
    esac
done <<< "$SUMMARY_DATA"

DURATION_MIN=$(( DURATION_SECS / 60 ))
DURATION_SEC=$(( DURATION_SECS % 60 ))

# --- Emit markdown summary ---
echo "# Session Tool Usage Summary"
echo ""
echo "**Session:** \`${SESSION_ID}\`"
if [[ "$DURATION_MIN" -gt 0 || "$DURATION_SEC" -gt 0 ]]; then
    echo "**Duration:** ${DURATION_MIN}m ${DURATION_SEC}s"
fi
echo "**Total tool calls:** ${TOTAL_CALLS}"
echo ""
echo "## Calls by Tool"
echo ""
printf '%s' "$TOOL_COUNTS_LINES"
echo ""
if [[ -n "$SLOW_CALLS_LINES" ]]; then
    echo "## Top 5 Slowest Calls (approx)"
    echo ""
    printf '%s' "$SLOW_CALLS_LINES"
    echo ""
fi

# --- 7-day log rotation ---
find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true

exit 0
