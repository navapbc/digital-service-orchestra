#!/usr/bin/env bash
set -uo pipefail
# lockpick-workflow/scripts/nohup-poll.sh
# Check completion status of a background task launched by nohup-launch.sh.
#
# Usage:
#   nohup-poll.sh <pid>
#
# Environment:
#   NOHUP_PID_DIR  PID registry directory (default: /tmp/workflow-nohup-pids)
#
# Output (stdout):
#   running          Task is still executing
#   completed:<N>    Task finished with exit code N
#   not_found        No entry file found for the given PID
#
# Exit codes:
#   0  Status determined (check stdout for result)
#   1  Invalid arguments

set -uo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: nohup-poll.sh <pid>" >&2
    exit 1
fi

PID="$1"

# ── Configuration ────────────────────────────────────────────────────────────
: "${NOHUP_PID_DIR:=/tmp/workflow-nohup-pids}"
: "${NOHUP_STALL_THRESHOLD:=300}"  # 5 minutes — heartbeat older than this = stalled

# ── Locate entry file ───────────────────────────────────────────────────────
ENTRY_FILE="$NOHUP_PID_DIR/${PID}.entry"

if [[ ! -f "$ENTRY_FILE" ]]; then
    echo "not_found"
    exit 0
fi

# ── Read entry fields ────────────────────────────────────────────────────────
EXIT_CODE_FILE=""
OUTPUT_FILE=""
while IFS='=' read -r key value; do
    case "$key" in
        EXIT_CODE_FILE) EXIT_CODE_FILE="$value" ;;
        OUTPUT_FILE) OUTPUT_FILE="$value" ;;
    esac
done < "$ENTRY_FILE"

# ── Determine status ────────────────────────────────────────────────────────
if [[ -n "$EXIT_CODE_FILE" ]] && [[ -f "$EXIT_CODE_FILE" ]]; then
    exit_code=$(cat "$EXIT_CODE_FILE" 2>/dev/null | tr -d '[:space:]')
    echo "completed:${exit_code}"
elif kill -0 "$PID" 2>/dev/null; then
    # Process alive — check heartbeat for stall detection
    HEARTBEAT_FILE="${OUTPUT_FILE}.heartbeat"
    if [[ -n "$OUTPUT_FILE" ]] && [[ -f "$HEARTBEAT_FILE" ]]; then
        last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null | tr -d '[:space:]')
        now=$(date +%s)
        if [[ -n "$last_heartbeat" ]] && (( now - last_heartbeat > NOHUP_STALL_THRESHOLD )); then
            echo "stalled:$(( now - last_heartbeat ))s"
        else
            echo "running"
        fi
    else
        echo "running"
    fi
else
    # Process gone but no exit code file — assume completed abnormally
    echo "completed:unknown"
fi
