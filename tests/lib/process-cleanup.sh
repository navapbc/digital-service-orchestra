#!/usr/bin/env bash
# tests/lib/process-cleanup.sh
# Session-safe process cleanup for the plugin test suite.
#
# Uses PID files keyed by session ID (worktree name or "main") so that
# cleanup only targets stale processes from the SAME session, not from
# other concurrent worktree sessions running their own test suites.
#
# Usage:
#   source "$PLUGIN_ROOT/tests/lib/process-cleanup.sh"
#
# Provides:
#   _write_pidfile <path> <pid> <session_id>
#   _remove_pidfile <path>
#   _read_session_from_pidfile <path>
#   _get_stale_pids_for_session <piddir> <session_id> <exclude_pid>
#   _cleanup_stale_session_processes <piddir> <session_id> <exclude_pid>
#   _get_session_id     — returns current session identifier
#   _get_pidfile_dir    — returns the PID file directory path
#
# PID file format (line 1: PID, line 2: session_id):
#   12345
#   worktree-20260313-141738

# _write_pidfile <path> <pid> <session_id>
_write_pidfile() {
    local path="$1" pid="$2" session_id="$3"
    printf '%s\n%s\n' "$pid" "$session_id" > "$path"
}

# _remove_pidfile <path>
_remove_pidfile() {
    rm -f "$1"
}

# _read_session_from_pidfile <path>
# Prints the session_id stored in the PID file.
_read_session_from_pidfile() {
    local path="$1"
    if [ -f "$path" ]; then
        sed -n '2p' "$path"
    fi
}

# _read_pid_from_pidfile <path>
# Prints the PID stored in the PID file.
_read_pid_from_pidfile() {
    local path="$1"
    if [ -f "$path" ]; then
        sed -n '1p' "$path"
    fi
}

# _get_stale_pids_for_session <piddir> <session_id> <exclude_pid>
# Finds PIDs from pidfiles matching <session_id> that are NOT <exclude_pid>.
# Prints space-separated list of PIDs (may be empty).
_get_stale_pids_for_session() {
    local piddir="$1" session_id="$2" exclude_pid="$3"
    local result=""

    for pidfile in "$piddir"/*.pid; do
        [ -f "$pidfile" ] || continue
        local file_session file_pid
        file_session=$(_read_session_from_pidfile "$pidfile")
        file_pid=$(_read_pid_from_pidfile "$pidfile")

        if [ "$file_session" = "$session_id" ] && [ "$file_pid" != "$exclude_pid" ]; then
            result="${result:+$result }$file_pid"
        fi
    done

    echo "$result"
}

# _cleanup_stale_session_processes <piddir> <session_id> <exclude_pid>
# Sends TERM then KILL to stale processes from this session.
# Removes their pidfiles after cleanup.
_cleanup_stale_session_processes() {
    local piddir="$1" session_id="$2" exclude_pid="$3"
    local stale_pids=()
    local stale_pidfiles=()

    # Collect stale PIDs and send TERM
    for pidfile in "$piddir"/*.pid; do
        [ -f "$pidfile" ] || continue
        local file_session file_pid
        file_session=$(_read_session_from_pidfile "$pidfile")
        file_pid=$(_read_pid_from_pidfile "$pidfile")

        if [ "$file_session" = "$session_id" ] && [ "$file_pid" != "$exclude_pid" ]; then
            stale_pids+=("$file_pid")
            stale_pidfiles+=("$pidfile")
            if kill -0 "$file_pid" 2>/dev/null; then
                kill -TERM "$file_pid" 2>/dev/null || true
            fi
        fi
    done

    # Brief pause for TERM to take effect, then KILL any survivors
    if [ ${#stale_pids[@]} -gt 0 ]; then
        sleep 0.2
        for i in "${!stale_pids[@]}"; do
            if kill -0 "${stale_pids[$i]}" 2>/dev/null; then
                kill -KILL "${stale_pids[$i]}" 2>/dev/null || true
            fi
            _remove_pidfile "${stale_pidfiles[$i]}"
        done
    fi
}

# _get_session_id
# Returns a stable identifier for the current session.
# Uses the worktree branch name or "main" for the main repo.
_get_session_id() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "$branch"
}

# _get_pidfile_dir
# Returns the directory where PID files are stored.
# Uses /tmp/lockpick-test-pids/ (shared across sessions, keyed by session_id).
_get_pidfile_dir() {
    local dir="/tmp/lockpick-test-pids"
    mkdir -p "$dir"
    echo "$dir"
}
