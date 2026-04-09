#!/usr/bin/env bash
# plugins/dso/scripts/ticket-transition.sh
# Transition a ticket's status with optimistic concurrency control and ghost prevention.
#
# Usage: ticket-transition.sh <ticket_id> <current_status> <target_status>
#   ticket_id: the ticket directory name (e.g., w21-ablv)
#   current_status: the status the caller believes the ticket is currently in
#   target_status: the status to transition to (open, in_progress, closed, blocked)
#
# Exits 0 on success or if current_status == target_status (no-op).
# Exits 1 on validation failure, ghost ticket, or concurrency rejection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket transition <ticket_id> <current_status> <target_status>" >&2
    echo "  current_status / target_status: open | in_progress | closed | blocked" >&2
    exit 1
}

# ── Validate arguments ───────────────────────────────────────────────────────
if [ $# -lt 3 ]; then
    _usage
fi

ticket_id="$1"
current_status="$2"
target_status="$3"
shift 3

# Parse optional --reason=<text> or --reason <text> from remaining args
close_reason=""
while [ $# -gt 0 ]; do
    case "$1" in
        --reason=*)
            close_reason="${1#--reason=}"
            shift
            ;;
        --reason)
            if [ $# -lt 2 ]; then
                echo "Error: --reason requires a value" >&2
                exit 1
            fi
            close_reason="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Validate statuses are in the allowed set
_validate_status() {
    local label="$1"
    local value="$2"
    case "$value" in
        open|in_progress|closed|blocked) ;;
        *)
            echo "Error: invalid ${label} '${value}'. Must be one of: open, in_progress, closed, blocked" >&2
            exit 1
            ;;
    esac
}

_validate_status "current_status" "$current_status"
_validate_status "target_status" "$target_status"

# ── Idempotent no-op ─────────────────────────────────────────────────────────
if [ "$current_status" = "$target_status" ]; then
    echo "No transition needed"
    exit 0
fi

# ── Step 1: Ghost check (before acquiring flock) ─────────────────────────────
if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
    echo "Error: ticket '$ticket_id' does not exist" >&2
    exit 1
fi

if ! find "$TRACKER_DIR/$ticket_id" -maxdepth 1 \( -name '*-CREATE.json' -o -name '*-SNAPSHOT.json' \) ! -name '.*' 2>/dev/null | grep -q .; then
    echo "Error: ticket $ticket_id has no CREATE or SNAPSHOT event" >&2
    exit 1
fi

# ── Validate ticket system is initialized ────────────────────────────────────
if [ ! -f "$TRACKER_DIR/.env-id" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

# ── Step 1b: Open-children guard (before flock — read-only check) ────────────
# REVIEW-DEFENSE: This check intentionally runs outside the flock. The TOCTOU
# window (a child ticket being created after this check but before the STATUS
# event is committed inside the flock) is an acceptable trade-off: the worst case
# is that a close succeeds while a sibling create is racing — which is already
# possible through direct event writes. The flock serializes STATUS event writes,
# not reads. Tightening this would require a separate lock on child creation, which
# adds complexity disproportionate to the risk.
#
# The open-children check runs via ticket-reducer.py directly (mandatory, fail-loud).
# batch_close_json is captured separately via the unblock script (non-critical, || true)
# and reused in Step 4 for unblock detection only — NOT for open-children detection.
batch_close_json=""
if [ "$target_status" = "closed" ]; then
    # ── Open-children guard: mandatory check via reducer (must NOT use || true) ──
    # Use ticket-reducer.py directly to find open children. This path is independent
    # of ticket-unblock.py so a broken/absent unblock script cannot mask children.
    open_children_check_exit=0
    open_children=$(python3 - "$TRACKER_DIR" "$ticket_id" "$REDUCER" <<'PYEOF' 2>&1) || open_children_check_exit=$?
import json, os, subprocess, sys

tracker_dir = sys.argv[1]
ticket_id = sys.argv[2]
reducer_path = sys.argv[3]

# Scan all ticket directories for open children (parent_id == ticket_id).
open_children = []
try:
    for entry in os.scandir(tracker_dir):
        if not entry.is_dir():
            continue
        tid = entry.name
        try:
            result = subprocess.run(
                ['python3', reducer_path, entry.path],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode != 0:
                continue
            state = json.loads(result.stdout)
        except Exception:
            continue
        if state.get('parent_id') != ticket_id:
            continue
        status = state.get('status', 'open')
        if status not in ('closed', 'done', 'resolved', 'cancelled', 'wont_fix', 'archived'):
            open_children.append(tid)
except Exception as e:
    print(f'Error: open-children scan failed: {e}', file=sys.stderr)
    sys.exit(2)

if open_children:
    print('\n'.join(open_children))
PYEOF

    if [ "$open_children_check_exit" -ne 0 ]; then
        echo "Error: open-children check failed — cannot safely close ticket '$ticket_id'" >&2
        echo "$open_children" >&2
        exit 1
    fi

    if [ -n "$open_children" ]; then
        open_children_count=$(echo "$open_children" | wc -l | tr -d ' ')
        echo "Error: cannot close ticket '$ticket_id' while it has ${open_children_count} open child ticket(s)." >&2
        echo "Close the following children first:" >&2
        echo "$open_children" >&2
        exit 1
    fi

    # ── Unblock detection: run ticket-unblock.py for newly_unblocked computation ─
    # This is non-critical — if the unblock script fails, the close still proceeds
    # (children were already verified absent above). batch_close_json is only used
    # in Step 4 for UNBLOCKED output, not for open-children detection.
    unblock_script="${DSO_UNBLOCK_SCRIPT:-$SCRIPT_DIR/ticket-unblock.py}"
    batch_close_json=$(python3 "$unblock_script" --batch-close "$TRACKER_DIR" "$ticket_id" 2>/dev/null) || true
fi

# ── Step 2-3: Acquire flock, read-verify-write inside lock ───────────────────
# All concurrency-critical operations (read current state, verify, build event,
# write event) happen inside a single flock to prevent TOCTOU races.
env_id=$(cat "$TRACKER_DIR/.env-id")
author=$(git config user.name 2>/dev/null || echo "Unknown")
lock_file="$TRACKER_DIR/.ticket-write.lock"

# The entire read-verify-write is done inside python3 holding fcntl.flock.
# If concurrency check fails, python exits 10 (mapped to exit 1 by caller).
# If lock timeout, python exits 1.
flock_exit=0
python3 -c "
import fcntl, json, os, subprocess, sys, time, uuid

lock_path = sys.argv[1]
tracker_dir = sys.argv[2]
ticket_id = sys.argv[3]
current_status = sys.argv[4]
target_status = sys.argv[5]
env_id_val = sys.argv[6]
author_val = sys.argv[7]
reducer_path = sys.argv[8]
close_reason = sys.argv[9] if len(sys.argv) > 9 else ''

timeout = 30

# Acquire flock
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
    print('Error: could not acquire lock', file=sys.stderr)
    sys.exit(1)

# Lock acquired — read current state via reducer
try:
    result = subprocess.run(
        ['python3', reducer_path, os.path.join(tracker_dir, ticket_id)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f'Error: reducer failed: {result.stderr.strip()}', file=sys.stderr)
        os.close(fd)
        sys.exit(1)

    state = json.loads(result.stdout)
    actual_status = state.get('status', '')

    # Optimistic concurrency check
    if actual_status != current_status:
        print(f'Error: current status is \"{actual_status}\", not \"{current_status}\"', file=sys.stderr)
        os.close(fd)
        sys.exit(10)

    # Bug-close-reason guard
    if target_status == 'closed':
        ticket_type = state.get('ticket_type', '')
        # If ticket_type is empty (old tickets predating the type field), treat as
        # non-bug: don't require --reason. This ensures backward compatibility.
        if ticket_type == 'bug':
            if not close_reason:
                print('Error: closing a bug ticket requires --reason with prefix \"Fixed:\" or \"Escalated to user:\"', file=sys.stderr)
                os.close(fd)
                sys.exit(1)
            # Validate required prefix: accept Fixed (covers Fixed:, Fixed in, etc.)
            # and case-insensitive escalat prefix (covers Escalated to user: variants).
            if not (close_reason.startswith('Fixed') or close_reason.lower().startswith('escalat')):
                print('Error: --reason must start with \"Fixed:\" or \"Escalated to user:\"', file=sys.stderr)
                os.close(fd)
                sys.exit(1)

    # Build STATUS event JSON
    timestamp = int(time.time())
    event_uuid = str(uuid.uuid4())
    event = {
        'timestamp': timestamp,
        'uuid': event_uuid,
        'event_type': 'STATUS',
        'env_id': env_id_val,
        'author': author_val,
        'data': {
            'status': target_status,
            'current_status': current_status,
        },
    }

    # Write to temp file
    temp_path = os.path.join(tracker_dir, f'.tmp-transition-{event_uuid}')
    with open(temp_path, 'w', encoding='utf-8') as f:
        json.dump(event, f, ensure_ascii=False)

    # Compute final filename and path
    final_filename = f'{timestamp}-{event_uuid}-STATUS.json'
    ticket_dir = os.path.join(tracker_dir, ticket_id)
    final_path = os.path.join(ticket_dir, final_filename)

    # Atomic rename
    os.rename(temp_path, final_path)

    # Ensure gc.auto=0
    subprocess.run(
        ['git', '-C', tracker_dir, 'config', 'gc.auto', '0'],
        check=True, capture_output=True, text=True,
    )

    # git add + commit
    subprocess.run(
        ['git', '-C', tracker_dir, 'add', f'{ticket_id}/{final_filename}'],
        check=True, capture_output=True, text=True,
    )
    subprocess.run(
        ['git', '-C', tracker_dir, 'commit', '-q', '--no-verify', '-m', f'ticket: STATUS {ticket_id}'],
        check=True, capture_output=True, text=True,
    )

except subprocess.CalledProcessError as e:
    print(f'Error: git operation failed: {e.stderr}', file=sys.stderr)
    # Clean up event file if it was written
    try:
        os.remove(final_path)
    except (OSError, NameError):
        pass
    os.close(fd)
    sys.exit(2)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    os.close(fd)
    sys.exit(1)

# Release lock
os.close(fd)
sys.exit(0)
" "$lock_file" "$TRACKER_DIR" "$ticket_id" "$current_status" "$target_status" "$env_id" "$author" "$REDUCER" "$close_reason" || flock_exit=$?

if [ "$flock_exit" -eq 10 ]; then
    # Optimistic concurrency rejection
    exit 1
elif [ "$flock_exit" -ne 0 ]; then
    exit 1
fi

# ── Step 4: Detect newly unblocked tickets (only on close) ───────────────────
if [ "$target_status" = "closed" ]; then
    # Use the batch_close_json captured in Step 1b (already computed open_children
    # and newly_unblocked in a single Python process — no second spawn needed).
    if [ -n "$batch_close_json" ]; then
        unblocked_ids=$(echo "$batch_close_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ids = d.get('newly_unblocked', [])
print(','.join(ids)) if ids else None
" 2>/dev/null) || unblocked_ids=""

        if [ -n "$unblocked_ids" ]; then
            echo "UNBLOCKED: $unblocked_ids"
        else
            echo "UNBLOCKED: none"
        fi
    else
        # batch_close_json was empty (e.g., unblock script failed) — warn but don't fail
        echo "Warning: batch-close JSON unavailable; unblock detection skipped" >&2
        echo "UNBLOCKED: none"
    fi

    # Compact-on-close: squash event log into SNAPSHOT (non-blocking)
    compact_script="${DSO_COMPACT_SCRIPT:-$SCRIPT_DIR/ticket-compact.sh}"
    bash "$compact_script" "$ticket_id" --threshold=0 --skip-sync 2>/dev/null || true
fi

exit 0
