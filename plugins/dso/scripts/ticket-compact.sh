#!/usr/bin/env bash
# plugins/dso/scripts/ticket-compact.sh
# Compact a ticket's event history into a single SNAPSHOT event.
#
# Usage: ticket-compact.sh <ticket_id> [--threshold=N]
# Default threshold: COMPACT_THRESHOLD env var or 10
#
# The compaction operation:
#   1. Lists event files (captured before flock)
#   2. Checks count against threshold — skips if below
#   3. Runs the reducer to compile current state
#   4. Acquires flock for the entire write+delete+commit pipeline
#   5. Writes a SNAPSHOT event with source_event_uuids
#   6. Deletes only the specific files read into the snapshot
#   7. Commits all changes atomically
#
# IMPORTANT: git operations are inlined (NOT via write_commit_event)
# to avoid nested flock deadlock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Usage ────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket-compact.sh <ticket_id> [--threshold=N]" >&2
    echo "  Default threshold: COMPACT_THRESHOLD env var or 10" >&2
    exit 1
}

# ── Parse arguments ──────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    _usage
fi

ticket_id="$1"
shift

threshold="${COMPACT_THRESHOLD:-10}"
while [ $# -gt 0 ]; do
    case "$1" in
        --threshold=*)
            threshold="${1#--threshold=}"
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            _usage
            ;;
    esac
    shift
done

# ── Validate ticket system ───────────────────────────────────────────────────
if [ ! -d "$TRACKER_DIR" ] || [ ! -f "$TRACKER_DIR/.git" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

ticket_dir="$TRACKER_DIR/$ticket_id"
if [ ! -d "$ticket_dir" ]; then
    echo "Error: ticket directory not found: $ticket_dir" >&2
    exit 1
fi

# ── Step 2: List event files (before flock) ──────────────────────────────────
# Capture the specific files that will be compacted.
# Sort lexicographically (= chronological by filename convention).
# Exclude dotfiles (.cache.json, etc.)
mapfile -t event_files < <(find "$ticket_dir" -maxdepth 1 -name '*.json' ! -name '.*' | sort)
event_count=${#event_files[@]}

# ── Step 3: Threshold check ─────────────────────────────────────────────────
if [ "$event_count" -le "$threshold" ]; then
    echo "below threshold ($event_count <= $threshold) — skipping compaction"
    exit 0
fi

# ── Step 4: Compile current state via reducer ────────────────────────────────
compiled_state_json=$(python3 "$SCRIPT_DIR/ticket-reducer.py" "$ticket_dir") || {
    echo "Error: reducer failed for ticket $ticket_id (corrupt or ghost ticket)" >&2
    exit 1
}

# Validate compiled state is not an error state
error_status=$(python3 -c "
import json, sys
state = json.loads(sys.argv[1])
s = state.get('status', '')
if s in ('error', 'fsck_needed'):
    print(s)
else:
    print('ok')
" "$compiled_state_json" 2>/dev/null) || error_status="parse_error"

if [ "$error_status" != "ok" ]; then
    echo "Error: ticket $ticket_id has status '$error_status' — cannot compact" >&2
    exit 1
fi

# ── Serialize event_files list to a temp file for Python ─────────────────────
event_list_tmp=$(mktemp)
printf '%s\n' "${event_files[@]}" > "$event_list_tmp"

# ── Step 5-7: Acquire flock for the entire operation ─────────────────────────
# Inlines git operations to avoid nested flock deadlock with write_commit_event.
lock_file="$TRACKER_DIR/.ticket-write.lock"

# Ensure gc.auto=0 in tickets worktree (idempotent guard)
git -C "$TRACKER_DIR" config gc.auto 0

max_retries=2
flock_timeout=30
attempt=0
lock_acquired=false

while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))

    flock_exit=0
    python3 - "$lock_file" "$flock_timeout" "$TRACKER_DIR" "$ticket_id" "$ticket_dir" "$compiled_state_json" "$event_list_tmp" << 'PYEOF' || flock_exit=$?
import fcntl, json, os, subprocess, sys, time, uuid

lock_path = sys.argv[1]
timeout = int(sys.argv[2])
tracker_dir = sys.argv[3]
ticket_id = sys.argv[4]
ticket_dir = sys.argv[5]
compiled_state_json = sys.argv[6]
event_list_file = sys.argv[7]

# Read event file paths from temp file
with open(event_list_file, encoding='utf-8') as f:
    event_files = [line.strip() for line in f if line.strip()]

# ── Acquire flock ────────────────────────────────────────────────────────
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

# ── Lock acquired — all operations below are under flock ─────────────────

# Re-check: if event files have been removed by a concurrent compaction, bail
still_present = [f for f in event_files if os.path.isfile(f)]
if len(still_present) == 0:
    # Already compacted by another process
    os.close(fd)
    sys.exit(0)

# Extract UUIDs from each event file (only files still present)
source_uuids = []
for filepath in event_files:
    try:
        with open(filepath, encoding='utf-8') as f:
            event = json.load(f)
        source_uuids.append(event.get('uuid', os.path.basename(filepath)))
    except (json.JSONDecodeError, OSError):
        source_uuids.append(os.path.basename(filepath))

# Read env_id from .env-id file
env_id_path = os.path.join(tracker_dir, '.env-id')
try:
    with open(env_id_path, encoding='utf-8') as f:
        env_id = f.read().strip()
except OSError:
    env_id = '00000000-0000-4000-8000-000000000000'

# Get author from git config
try:
    result = subprocess.run(
        ['git', 'config', 'user.name'],
        capture_output=True, text=True, check=True,
    )
    author = result.stdout.strip()
except subprocess.CalledProcessError:
    author = 'system'

# Build SNAPSHOT event
compiled_state = json.loads(compiled_state_json)
snapshot_uuid = str(uuid.uuid4())
snapshot_timestamp = int(time.time())

snapshot_event = {
    'event_type': 'SNAPSHOT',
    'timestamp': snapshot_timestamp,
    'uuid': snapshot_uuid,
    'env_id': env_id,
    'author': author,
    'data': {
        'compiled_state': compiled_state,
        'source_event_uuids': source_uuids,
        'compacted_at': snapshot_timestamp,
    },
}

# Write SNAPSHOT to temp file, then atomic rename
snapshot_filename = f'{snapshot_timestamp}-{snapshot_uuid}-SNAPSHOT.json'
final_path = os.path.join(ticket_dir, snapshot_filename)
staging_temp = final_path + '.tmp'

with open(staging_temp, 'w', encoding='utf-8') as f:
    json.dump(snapshot_event, f, ensure_ascii=False)
os.rename(staging_temp, final_path)

# Delete original event files (only the specific files captured before flock)
for filepath in event_files:
    try:
        os.remove(filepath)
    except OSError:
        pass  # Already removed by concurrent process

# Invalidate cache (snapshot changed the state representation)
cache_path = os.path.join(ticket_dir, '.cache.json')
try:
    os.remove(cache_path)
except OSError:
    pass

# Stage all changes in the ticket dir and commit atomically
# Using git add -A on the ticket subdir handles both additions and deletions
try:
    subprocess.run(
        ['git', '-C', tracker_dir, 'add', '-A', f'{ticket_id}/'],
        check=True, capture_output=True, text=True,
    )
    # Only commit if there are staged changes
    status_result = subprocess.run(
        ['git', '-C', tracker_dir, 'diff', '--cached', '--quiet'],
        capture_output=True, text=True,
    )
    if status_result.returncode != 0:
        subprocess.run(
            ['git', '-C', tracker_dir, 'commit', '-q', '-m',
             f'ticket: COMPACT {ticket_id}'],
            check=True, capture_output=True, text=True,
        )
except subprocess.CalledProcessError as e:
    print(f'Error: git compact commit failed: {e.stderr}', file=sys.stderr)
    os.close(fd)
    sys.exit(2)

# Release lock
os.close(fd)
sys.exit(0)
PYEOF

    if [ "$flock_exit" -eq 0 ]; then
        lock_acquired=true
        break
    elif [ "$flock_exit" -eq 2 ]; then
        echo "Error: git operation failed while holding lock" >&2
        rm -f "$event_list_tmp"
        exit 1
    fi
done

rm -f "$event_list_tmp"

if [ "$lock_acquired" = false ]; then
    total_wait=$((flock_timeout * max_retries))
    echo "Error: flock: could not acquire lock after ${total_wait}s" >&2
    exit 1
fi

echo "compacted $event_count events into SNAPSHOT for $ticket_id"
exit 0
