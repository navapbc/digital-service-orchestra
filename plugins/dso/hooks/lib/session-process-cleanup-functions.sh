#!/usr/bin/env bash
# hooks/lib/session-process-cleanup-functions.sh
# Sourceable function definitions for session process cleanup hooks.
#
# Each function follows the hook contract:
#   Return 0: allow — continue to next hook
#   stderr: warnings (always allowed; passed through by dispatcher)
#
# Functions defined:
#   hook_cleanup_orphaned_processes   — kill nohup-orphaned processes older than 30 min
#   hook_cleanup_stale_nohup          — reap stale/hung processes from PID registry
#
# Usage:
#   source hooks/lib/session-process-cleanup-functions.sh
#   hook_cleanup_orphaned_processes

# Guard: only load once
[[ "${_SESSION_PROCESS_CLEANUP_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_SESSION_PROCESS_CLEANUP_FUNCTIONS_LOADED=1

# ---------------------------------------------------------------------------
# hook_cleanup_orphaned_processes
# ---------------------------------------------------------------------------
# SessionStart hook: kill nohup-orphaned processes older than 30 minutes.
# These accumulate from the nohup + file-based polling pattern (INC-016
# workaround) and never get cleaned up. Uses process age to avoid killing
# processes from concurrent sessions.
hook_cleanup_orphaned_processes() {
    local AGE_THRESHOLD_MIN=30
    local NOW_EPOCH
    NOW_EPOCH=$(date +%s)

    # Patterns for known nohup-orphaned commands
    local PATTERNS=(
        "timeout.*make.*test-e2e"
        "timeout.*make.*test-unit"
        "timeout.*make.*test-integration"
        "timeout.*validate\.sh"
    )

    local KILLED=0
    for pattern in "${PATTERNS[@]}"; do
        # Get PIDs matching the pattern (exclude grep itself)
        local PIDS
        PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
        if [[ -z "$PIDS" ]]; then
            continue
        fi

        for pid in $PIDS; do
            # Get process start time (elapsed seconds since start)
            local ELAPSED
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS: ps -o etime gives [[dd-]hh:]mm:ss
                local ETIME
                ETIME=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ') || continue
                # Skip if process vanished between pgrep and ps
                [[ -z "$ETIME" ]] && continue
                # Parse etime to seconds
                local DAYS=0 HOURS=0 MINS=0 SECS=0
                if [[ "$ETIME" == *-* ]]; then
                    DAYS="${ETIME%%-*}"
                    ETIME="${ETIME#*-}"
                fi
                # Count colons to determine format
                local COLON_COUNT
                COLON_COUNT=$(echo "$ETIME" | tr -cd ':' | wc -c | tr -d ' ')
                if [[ "$COLON_COUNT" -eq 2 ]]; then
                    HOURS=$(echo "$ETIME" | cut -d: -f1)
                    MINS=$(echo "$ETIME" | cut -d: -f2)
                    SECS=$(echo "$ETIME" | cut -d: -f3)
                elif [[ "$COLON_COUNT" -eq 1 ]]; then
                    MINS=$(echo "$ETIME" | cut -d: -f1)
                    SECS=$(echo "$ETIME" | cut -d: -f2)
                fi
                # Remove leading zeros
                DAYS=$((10#$DAYS)) HOURS=$((10#$HOURS)) MINS=$((10#$MINS)) SECS=$((10#$SECS))
                ELAPSED=$(( DAYS*86400 + HOURS*3600 + MINS*60 + SECS ))
            else
                # Linux: use /proc
                local START_TIME
                START_TIME=$(stat -c %Y "/proc/$pid" 2>/dev/null) || continue
                ELAPSED=$(( NOW_EPOCH - START_TIME ))
            fi

            local AGE_MIN=$(( ELAPSED / 60 ))
            if [[ "$AGE_MIN" -ge "$AGE_THRESHOLD_MIN" ]]; then
                # Resolve actual PGID — do not assume PID == PGID
                local ACTUAL_PGID
                ACTUAL_PGID=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || ACTUAL_PGID=""
                if [[ -n "$ACTUAL_PGID" && "$ACTUAL_PGID" =~ ^[0-9]+$ ]]; then
                    # Kill the process group using resolved PGID
                    kill -- -"$ACTUAL_PGID" 2>/dev/null || kill "$pid" 2>/dev/null || true
                else
                    # Fallback: kill individual process if PGID lookup fails
                    kill "$pid" 2>/dev/null || true
                fi
                KILLED=$((KILLED + 1))
            fi
        done
    done

    if [[ "$KILLED" -gt 0 ]]; then
        echo "Cleaned up $KILLED orphaned background process(es) older than ${AGE_THRESHOLD_MIN} minutes." >&2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_cleanup_stale_nohup
# ---------------------------------------------------------------------------
# SessionStart hook: scan the nohup PID registry and clean up stale/hung
# processes. Only kills processes that are registered in the registry AND
# whose command matches the entry metadata (PID recycling protection).
#
# Registry: /tmp/workflow-nohup-pids/*.entry (override via NOHUP_PID_REGISTRY)
# Entry format (line-oriented key=value):
#   pid=<PID>
#   command=<original command line>
#   started=<epoch seconds>
#
# Cleanup rules:
#   - Process not running (dead PID): remove entry file
#   - Process running >1h AND command matches: kill process, remove entry
#   - Process running but command does NOT match (PID recycled): remove entry only
#   - Process running <1h with matching command: leave alone
hook_cleanup_stale_nohup() {
    local REGISTRY="${NOHUP_PID_REGISTRY:-/tmp/workflow-nohup-pids}"
    local AGE_THRESHOLD_SEC=3600  # 1 hour
    local NOW_EPOCH
    NOW_EPOCH=$(date +%s)

    # No registry directory or no entry files — nothing to do
    if [[ ! -d "$REGISTRY" ]]; then
        return 0
    fi

    local ENTRY_FILES
    ENTRY_FILES=$(ls "$REGISTRY"/*.entry 2>/dev/null || true)
    if [[ -z "$ENTRY_FILES" ]]; then
        return 0
    fi

    local CLEANED=0
    local entry_file
    for entry_file in $ENTRY_FILES; do
        [[ -f "$entry_file" ]] || continue

        # Parse entry file
        local entry_pid="" entry_command="" entry_started=""
        while IFS='=' read -r key val; do
            case "$key" in
                pid) entry_pid="$val" ;;
                command) entry_command="$val" ;;
                started) entry_started="$val" ;;
            esac
        done < "$entry_file"

        # Skip malformed entries
        if [[ -z "$entry_pid" || ! "$entry_pid" =~ ^[0-9]+$ ]]; then
            rm -f "$entry_file"
            continue
        fi

        # Check if process is still running
        if ! kill -0 "$entry_pid" 2>/dev/null; then
            # Process is dead — remove entry
            rm -f "$entry_file"
            CLEANED=$((CLEANED + 1))
            continue
        fi

        # Process is alive — check command match (PID recycling protection)
        local actual_cmd
        actual_cmd=$(ps -o command= -p "$entry_pid" 2>/dev/null | head -1) || actual_cmd=""

        if [[ -z "$entry_command" || "$actual_cmd" != *"$entry_command"* && "$entry_command" != *"$actual_cmd"* ]]; then
            # Command mismatch — PID was recycled. Remove stale entry but don't kill.
            rm -f "$entry_file"
            CLEANED=$((CLEANED + 1))
            continue
        fi

        # Command matches — check age
        if [[ -n "$entry_started" && "$entry_started" =~ ^[0-9]+$ ]]; then
            local age=$(( NOW_EPOCH - entry_started ))
            if [[ "$age" -ge "$AGE_THRESHOLD_SEC" ]]; then
                # Process has been running too long — kill process group if leader
                local actual_pgid
                actual_pgid=$(ps -o pgid= -p "$entry_pid" 2>/dev/null | tr -d ' ') || actual_pgid=""
                if [[ -n "$actual_pgid" && "$actual_pgid" == "$entry_pid" ]]; then
                    # Process is the group leader (typical for nohup) — kill the group
                    kill -- -"$actual_pgid" 2>/dev/null || kill "$entry_pid" 2>/dev/null || true
                else
                    # Not a group leader — kill only the registered PID
                    kill "$entry_pid" 2>/dev/null || true
                fi
                rm -f "$entry_file"
                CLEANED=$((CLEANED + 1))
                continue
            fi
        fi

        # Process is alive, command matches, and under threshold — leave it
    done

    if [[ "$CLEANED" -gt 0 ]]; then
        echo "Cleaned up $CLEANED stale nohup process(es) from registry." >&2
    fi

    return 0
}
