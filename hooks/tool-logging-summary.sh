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

# This hook uses jq extensively for JSONL processing — skip entirely without jq
check_tool jq || exit 0

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

# --- Filter entries for this session ---
SESSION_ENTRIES=$(jq -c --arg sid "$SESSION_ID" \
    'select(.session_id == $sid)' "$LOG_FILE" 2>/dev/null || echo "")

if [[ -z "$SESSION_ENTRIES" ]]; then
    exit 0
fi

# Require at least 10 tool calls (post entries) to emit a summary
POST_ENTRIES=$(echo "$SESSION_ENTRIES" | jq -c 'select(.hook_type == "post")' 2>/dev/null || echo "")
TOTAL_CALLS=$(echo "$POST_ENTRIES" | grep -c '"hook_type":"post"' 2>/dev/null || echo "0")

if [[ "$TOTAL_CALLS" -lt 10 ]]; then
    # --- Log rotation (always run regardless of threshold) ---
    find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true
    exit 0
fi

# --- Tool call counts by tool_name (post entries only) ---
TOOL_COUNTS=$(echo "$POST_ENTRIES" | \
    jq -rs '[.[] | .tool_name] | group_by(.) | map({tool: .[0], count: length}) | sort_by(-.count)' \
    2>/dev/null || echo "[]")

# --- Session duration: first to last entry (all entries) ---
ALL_EPOCHS=$(echo "$SESSION_ENTRIES" | jq -r '.epoch_ms' 2>/dev/null | sort -n)
FIRST_EPOCH=$(echo "$ALL_EPOCHS" | head -1)
LAST_EPOCH=$(echo "$ALL_EPOCHS" | tail -1)

DURATION_SECS=0
if [[ -n "$FIRST_EPOCH" && -n "$LAST_EPOCH" && "$FIRST_EPOCH" -gt 0 && "$LAST_EPOCH" -gt "$FIRST_EPOCH" ]]; then
    DURATION_SECS=$(( (LAST_EPOCH - FIRST_EPOCH) / 1000 ))
fi

DURATION_MIN=$(( DURATION_SECS / 60 ))
DURATION_SEC=$(( DURATION_SECS % 60 ))

# --- Best-effort: top 5 slowest calls (pair pre/post by tool_name + time proximity) ---
# Strategy: for each post entry, find the nearest preceding pre entry for the same tool.
# Emit delta in seconds. Sort descending, take top 5.
SLOW_CALLS=$(echo "$SESSION_ENTRIES" | jq -rs '
    # Separate pre and post entries
    . as $all |
    [ $all[] | select(.hook_type == "pre") ]  as $pres |
    [ $all[] | select(.hook_type == "post") ] as $posts |
    # For each post, find closest preceding pre with same tool_name
    [ $posts[] as $p |
      [ $pres[] | select(.tool_name == $p.tool_name and .epoch_ms <= $p.epoch_ms) ] |
      sort_by(.epoch_ms) | last |
      if . then
        { tool: $p.tool_name, delta_ms: ($p.epoch_ms - .epoch_ms) }
      else
        empty
      end
    ] |
    sort_by(-.delta_ms) | .[0:5] |
    map("  - \(.tool): \(.delta_ms / 1000 | floor)s")[]
' 2>/dev/null || echo "")

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
echo "$TOOL_COUNTS" | jq -r '.[] | "  - \(.tool): \(.count)"' 2>/dev/null || true
echo ""
if [[ -n "$SLOW_CALLS" ]]; then
    echo "## Top 5 Slowest Calls (approx)"
    echo ""
    echo "$SLOW_CALLS"
    echo ""
fi

# --- 7-day log rotation ---
find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true

exit 0
