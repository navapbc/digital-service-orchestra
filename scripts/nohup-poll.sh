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
#   completed:unknown  Task is/was a zombie process (reaped) or exited without exit code
#   stalled:<N>s     Process alive but heartbeat not updated for <N> seconds
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

# ── Zombie detection helper ──────────────────────────────────────────────────
# _is_zombie <pid>
# Returns 0 (true) if the process is in zombie/defunct state, 1 otherwise.
# Cross-platform: uses /proc/<pid>/status on Linux, ps -o state= on macOS.
_is_zombie() {
    local pid="$1"
    if [[ -r "/proc/${pid}/status" ]]; then
        # Linux: read State field from /proc/<pid>/status
        local proc_state
        proc_state=$(awk '/^State:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)
        [[ "$proc_state" == "Z" ]]
    else
        # macOS / other: use ps to read process state
        local ps_state
        ps_state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$ps_state" == Z* ]]
    fi
}

# ── Locate entry file ───────────────────────────────────────────────────────
ENTRY_FILE="$NOHUP_PID_DIR/${PID}.entry"

if [[ ! -f "$ENTRY_FILE" ]]; then
    echo "not_found"
    exit 0
fi

# ── Read entry fields ────────────────────────────────────────────────────────
EXIT_CODE_FILE=""
OUTPUT_FILE=""
LAUNCH_TIMESTAMP=""
while IFS='=' read -r key value; do
    case "$key" in
        EXIT_CODE_FILE)    EXIT_CODE_FILE="$value" ;;
        OUTPUT_FILE)       OUTPUT_FILE="$value" ;;
        LAUNCH_TIMESTAMP)  LAUNCH_TIMESTAMP="$value" ;;
    esac
done < "$ENTRY_FILE"

# ── Determine status ────────────────────────────────────────────────────────
if [[ -n "$EXIT_CODE_FILE" ]] && [[ -f "$EXIT_CODE_FILE" ]]; then
    exit_code=$(cat "$EXIT_CODE_FILE" 2>/dev/null | tr -d '[:space:]')
    echo "completed:${exit_code}"
elif kill -0 "$PID" 2>/dev/null; then
    # Process is reachable — check if it is a zombie (defunct)
    if _is_zombie "$PID"; then
        # Attempt to reap the zombie; collect exit status if available
        wait "$PID" 2>/dev/null || true
        echo "completed:unknown"
    else
        # Process alive and not zombie — check heartbeat for stall detection
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
            # Heartbeat file missing — process may have crashed before writing it.
            # Use entry file age as a proxy: if it is older than NOHUP_STALL_THRESHOLD,
            # the process has been running (without a heartbeat) for too long → stalled.
            now=$(date +%s)
            # Portable entry-file mtime: stat -c on Linux, stat -f on macOS
            if stat --version 2>/dev/null | grep -q GNU; then
                entry_mtime=$(stat -c '%Y' "$ENTRY_FILE" 2>/dev/null || echo "$now")
            else
                entry_mtime=$(stat -f '%m' "$ENTRY_FILE" 2>/dev/null || echo "$now")
            fi
            age=$(( now - entry_mtime ))
            if (( age >= NOHUP_STALL_THRESHOLD )); then
                echo "stalled:${age}s"
            else
                echo "running"
            fi
        fi
    fi
else
    # Process gone but no exit code file — assume completed abnormally
    echo "completed:unknown"
fi
