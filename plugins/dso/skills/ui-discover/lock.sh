#!/usr/bin/env bash
# UI Discovery Cache lock manager
# Prevents concurrent /dso:ui-discover runs from corrupting the cache.
#
# Uses mkdir for atomic lock acquisition (race-free on POSIX filesystems).
# Records owning PID for stale-lock detection.
#
# Usage:
#   lock.sh acquire          # Acquire lock (exit 0) or fail (exit 1)
#   lock.sh release          # Release lock owned by current shell
#   lock.sh release --force  # Force-release (manual recovery)
#   lock.sh status           # Print lock info; exit 0=locked, 1=unlocked

set -euo pipefail

LOCK_DIR=".ui-discovery-cache/.lock"
PID_FILE="$LOCK_DIR/pid"

acquire() {
    # Ensure parent directory exists
    mkdir -p .ui-discovery-cache

    # Atomic lock attempt
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $PPID > "$PID_FILE"
        echo "Lock acquired by PID $PPID"
        exit 0
    fi

    # Lock exists — check if holder is still alive
    if [ -f "$PID_FILE" ]; then
        HOLDER_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
            echo "Lock held by live process PID $HOLDER_PID"
            exit 1
        else
            # Stale lock — previous holder died
            echo "Reclaiming stale lock (previous holder PID ${HOLDER_PID:-unknown} is dead)"
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || {
                echo "Failed to reclaim lock (race condition)"
                exit 1
            }
            echo $PPID > "$PID_FILE"
            echo "Lock acquired by PID $PPID"
            exit 0
        fi
    fi

    # Lock dir exists but no PID file — treat as stale
    echo "Reclaiming orphaned lock (no PID file)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || {
        echo "Failed to reclaim lock (race condition)"
        exit 1
    }
    echo $PPID > "$PID_FILE"
    echo "Lock acquired by PID $PPID"
    exit 0
}

release() {
    local force="${1:-}"

    if [ ! -d "$LOCK_DIR" ]; then
        echo "No lock to release"
        exit 0
    fi

    if [ "$force" = "--force" ]; then
        rm -rf "$LOCK_DIR"
        echo "Lock force-released"
        exit 0
    fi

    # Only release if we own it
    if [ -f "$PID_FILE" ]; then
        HOLDER_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ "$HOLDER_PID" = "$PPID" ]; then
            rm -rf "$LOCK_DIR"
            echo "Lock released by PID $PPID"
            exit 0
        else
            echo "Lock owned by PID $HOLDER_PID, not $PPID. Use --force to override."
            exit 1
        fi
    fi

    # No PID file — safe to clean up
    rm -rf "$LOCK_DIR"
    echo "Orphaned lock released"
    exit 0
}

status() {
    if [ ! -d "$LOCK_DIR" ]; then
        echo "Unlocked"
        exit 1
    fi

    if [ -f "$PID_FILE" ]; then
        HOLDER_PID=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
        LOCK_AGE=""
        if command -v stat >/dev/null 2>&1; then
            if [[ "$OSTYPE" == darwin* ]]; then
                LOCK_MTIME=$(stat -f %m "$PID_FILE" 2>/dev/null || echo "")
            else
                LOCK_MTIME=$(stat -c %Y "$PID_FILE" 2>/dev/null || echo "")
            fi
            if [ -n "$LOCK_MTIME" ]; then
                NOW=$(date +%s)
                LOCK_AGE=$(( NOW - LOCK_MTIME ))
            fi
        fi

        ALIVE="dead"
        if [ "$HOLDER_PID" != "unknown" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
            ALIVE="alive"
        fi

        if [ -n "$LOCK_AGE" ]; then
            echo "Locked by PID $HOLDER_PID ($ALIVE, ${LOCK_AGE}s ago)"
        else
            echo "Locked by PID $HOLDER_PID ($ALIVE)"
        fi
        exit 0
    fi

    echo "Locked (no PID file — orphaned)"
    exit 0
}

# --- Main ---
CMD="${1:-}"
case "$CMD" in
    acquire) acquire ;;
    release) release "${2:-}" ;;
    status)  status ;;
    *)
        echo "Usage: lock.sh {acquire|release [--force]|status}"
        exit 2
        ;;
esac
