#!/usr/bin/env bash
# plugins/dso/scripts/ticket-lib.sh
# Shared library for ticket event writing. Sourced (not executed) by ticket commands.
#
# Provides:
#   write_commit_event <ticket_id> <temp_event_json_path>
#     Atomically writes an event file and commits it to the tickets branch.
#
# Requirements:
#   - ticket init must have been run (.tickets-tracker/ worktree must exist)
#   - python3 must be available (for JSON parsing)
#   - python3 fcntl.flock used for portable serialization (macOS + Linux)

# write_commit_event <ticket_id> <temp_event_json_path>
# Args:
#   ticket_id: the ticket directory name (e.g., w21-ablv)
#   temp_event_json_path: path to the fully-constructed JSON event file (temp file)
#
# Steps:
#   1. Validates .tickets-tracker/ exists and is a valid worktree
#   2. Reads event_type, timestamp, uuid from JSON via python3
#   3. Creates ticket dir: mkdir -p .tickets-tracker/<ticket_id>
#   4. Stages temp file in .tickets-tracker/ (same filesystem for atomic rename)
#   5. Acquires flock on .tickets-tracker/.ticket-write.lock
#   6. Atomic rename: mv staging_temp → final_path (inside lock)
#   7. git add <specific-file> + git commit (inside lock)
#   8. Releases flock
write_commit_event() {
    local ticket_id="$1"
    local temp_event_json_path="$2"

    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local tracker_dir_raw="$repo_root/.tickets-tracker"
    # Resolve to canonical path so that callers using a symlink and callers using
    # the real path always contend on the same lock file (cross-path serialization).
    local tracker_dir
    tracker_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$tracker_dir_raw")
    local lock_file="$tracker_dir/.ticket-write.lock"

    # ── Validate: ticket system must be initialized ──────────────────────────
    if [ ! -d "$tracker_dir" ] || [ ! -f "$tracker_dir/.git" ]; then
        echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
        return 1
    fi
    if ! git -C "$tracker_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: .tickets-tracker is not a valid git worktree." >&2
        return 1
    fi

    # ── Validate: temp event JSON exists ─────────────────────────────────────
    if [ ! -f "$temp_event_json_path" ]; then
        echo "Error: event JSON file not found: $temp_event_json_path" >&2
        return 1
    fi

    # ── Extract event metadata via python3 ───────────────────────────────────
    local event_meta
    event_meta=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(data['event_type'])
print(data['timestamp'])
print(data['uuid'])
" "$temp_event_json_path") || {
        echo "Error: failed to parse event JSON" >&2
        return 1
    }

    local event_type timestamp uuid
    event_type=$(echo "$event_meta" | sed -n '1p')
    timestamp=$(echo "$event_meta" | sed -n '2p')
    uuid=$(echo "$event_meta" | sed -n '3p')

    # ── Normalize event_type to uppercase and validate against allowed enum ──
    event_type=$(echo "$event_type" | tr '[:lower:]' '[:upper:]')
    case "$event_type" in
        CREATE|STATUS|COMMENT|LINK|UNLINK|SNAPSHOT|SYNC|REVERT|EDIT|ARCHIVED) ;;
        *)
            echo "Error: invalid event_type '$event_type'. Must be one of: CREATE, STATUS, COMMENT, LINK, UNLINK, SNAPSHOT, SYNC, REVERT, EDIT, ARCHIVED" >&2
            return 1
            ;;
    esac

    # ── Determine final filename ─────────────────────────────────────────────
    local final_filename="${timestamp}-${uuid}-${event_type}.json"
    local ticket_dir="$tracker_dir/$ticket_id"
    local final_path="$ticket_dir/$final_filename"

    # ── Create ticket directory ──────────────────────────────────────────────
    mkdir -p "$ticket_dir"

    # ── Stage temp file in .tickets-tracker/ (same filesystem for atomic rename)
    # mktemp in .tickets-tracker/ ensures same-filesystem atomic mv inside flock
    local staging_temp
    staging_temp=$(mktemp "$tracker_dir/.tmp-event-XXXXXX")
    python3 -c "
import json, sys, shutil
# Read source and rewrite with explicit UTF-8 encoding
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    json.dump(data, f)
" "$temp_event_json_path" "$staging_temp" || {
        rm -f "$staging_temp"
        echo "Error: failed to write staging temp file" >&2
        return 1
    }
    # ── Ensure gc.auto=0 in tickets worktree (idempotent guard) ──────────────
    git -C "$tracker_dir" config gc.auto 0

    # ── Acquire flock, then atomic rename + commit ───────────────────────────
    # Uses python3 fcntl.flock for portable locking (macOS + Linux).
    # Lock file: .tickets-tracker/.ticket-write.lock
    # The Python process holds the lock while running:
    #   1. Atomic rename (staging_temp → final_path)
    #   2. git add <specific-file>
    #   3. git commit
    # This ensures the entire write-rename-commit pipeline is serialized.
    # Budget: 30s timeout per attempt, max 2 retries (60s total)
    local max_retries=2
    local flock_timeout=30
    local attempt=0
    local lock_acquired=false

    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))

        # Acquire flock, then rename + git add + commit while holding the lock
        local flock_exit=0
        python3 -c "
import fcntl, os, subprocess, sys, time

lock_path = sys.argv[1]
timeout = int(sys.argv[2])
tracker_dir = sys.argv[3]
ticket_id = sys.argv[4]
final_filename = sys.argv[5]
event_type = sys.argv[6]
staging_temp = sys.argv[7]
final_path = sys.argv[8]

fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
deadline = time.monotonic() + timeout
acquired = False
while time.monotonic() < deadline:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        break
    except (IOError, OSError):
        time.sleep(0.1)
if not acquired:
    os.close(fd)
    sys.exit(1)

# Lock acquired — atomic rename then git operations while holding the lock
try:
    os.rename(staging_temp, final_path)
except OSError as e:
    print(f'Error: atomic rename failed: {e}', file=sys.stderr)
    os.close(fd)
    sys.exit(3)

try:
    subprocess.run(
        ['git', '-C', tracker_dir, 'add', f'{ticket_id}/{final_filename}'],
        check=True, capture_output=True, text=True,
    )
    subprocess.run(
        ['git', '-C', tracker_dir, 'commit', '-q', '--no-verify', '-m', f'ticket: {event_type} {ticket_id}'],
        check=True, capture_output=True, text=True,
    )
except subprocess.CalledProcessError as e:
    print(f'Error: git operation failed: {e.stderr}', file=sys.stderr)
    # Clean up the event file so it doesn't remain uncommitted on disk
    try:
        os.remove(final_path)
    except OSError:
        pass
    os.close(fd)
    sys.exit(2)

# Release lock by closing fd
os.close(fd)
sys.exit(0)
" "$lock_file" "$flock_timeout" "$tracker_dir" "$ticket_id" "$final_filename" "$event_type" "$staging_temp" "$final_path" || flock_exit=$?

        if [ "$flock_exit" -eq 0 ]; then
            lock_acquired=true
            break
        elif [ "$flock_exit" -eq 2 ]; then
            # git operation failed (not a lock timeout) — don't retry
            echo "Error: git commit failed while holding lock" >&2
            return 1
        elif [ "$flock_exit" -eq 3 ]; then
            # atomic rename failed — clean up staging temp and don't retry
            rm -f "$staging_temp"
            echo "Error: atomic rename failed" >&2
            return 1
        fi
    done

    if [ "$lock_acquired" = false ]; then
        local total_wait=$((flock_timeout * max_retries))
        echo "flock: could not acquire lock after ${total_wait}s" >&2
        # Clean up: staging temp still exists since rename is inside the lock
        rm -f "$staging_temp"
        return 1
    fi

    return 0
}

# ticket_read_status <tracker_dir> <ticket_id>
# Returns the current compiled status of a ticket (e.g., open, in_progress, closed, blocked).
# Computes REDUCER path internally from BASH_SOURCE — does NOT rely on caller-set globals.
#
# Args:
#   tracker_dir: path to .tickets-tracker worktree (passed by caller)
#   ticket_id:   ticket directory name (e.g., dso-abc1)
#
# Outputs the status string to stdout. Exits non-zero on error.
ticket_read_status() {
    local tracker_dir="$1"
    local ticket_id="$2"

    # Resolve REDUCER path relative to this script's location
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local reducer="$lib_dir/ticket-reducer.py"

    local ticket_dir="$tracker_dir/$ticket_id"

    if [ ! -d "$ticket_dir" ]; then
        echo "Error: ticket directory not found: $ticket_dir" >&2
        return 1
    fi

    local state_json
    state_json=$(python3 "$reducer" "$ticket_dir" 2>/dev/null) || {
        echo "Error: reducer failed for ticket $ticket_id" >&2
        return 1
    }

    python3 -c "
import json, sys
state = json.loads(sys.argv[1])
print(state.get('status', ''))
" "$state_json"
}
