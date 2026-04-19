#!/usr/bin/env bash
# emit-review-event.sh
# Writes a review observability event as a JSONL file to .review-events/
# within the tickets tracker (.tickets-tracker/).
#
# Usage: bash emit-review-event.sh '<json_payload>'
#
# The JSON payload must contain at minimum:
#   - event_type: one of review_result, commit_workflow, tier_selection, overlay_trigger
#   - All other fields are passed through as-is to the JSONL output
#
# The script ensures:
#   - schema_version=1 and timestamp are always present
#   - Unique filenames via timestamp + random suffix
#   - Atomic write via _flock_stage_commit from ticket-lib.sh
#   - Graceful failure (non-zero exit + stderr message; never crashes caller)
#
# Environment variables:
#   REVIEW_EVENT_LOCK_TIMEOUT — override flock timeout in seconds (default: 30)
#     Used for testability (e.g., lock-exhaustion tests).

set -uo pipefail

# ── Resolve paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source ticket-lib.sh for _flock_stage_commit
if [ ! -f "$SCRIPT_DIR/ticket-lib.sh" ]; then
    echo "Error: ticket-lib.sh not found at $SCRIPT_DIR/ticket-lib.sh" >&2
    exit 1
fi
source "$SCRIPT_DIR/ticket-lib.sh"

# ── Validate arguments ────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Error: missing JSON payload argument" >&2
    echo "Usage: emit-review-event.sh '<json_payload>'" >&2
    exit 1
fi

json_payload="$1"

# ── Validate and extract event_type from JSON ─────────────────────────────
VALID_EVENT_TYPES="review_result commit_workflow tier_selection overlay_trigger"

event_type=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data.get('event_type', ''))
except Exception:
    print('')
" "$json_payload" 2>/dev/null) || {
    echo "Error: failed to parse JSON payload" >&2
    exit 1
}

if [ -z "$event_type" ]; then
    echo "Error: event_type field missing from payload" >&2
    exit 1
fi

# Validate event_type against allowed set
valid=false
for t in $VALID_EVENT_TYPES; do
    if [ "$t" = "$event_type" ]; then
        valid=true
        break
    fi
done
if [ "$valid" = false ]; then
    echo "Error: invalid event_type '$event_type' — must be one of: $VALID_EVENT_TYPES" >&2
    exit 1
fi

# ── Locate .tickets-tracker ───────────────────────────────────────────────
# Respect PROJECT_ROOT exported by the .claude/scripts/dso shim (bb42-1291).
repo_root="${PROJECT_ROOT:-}"
if [ -z "$repo_root" ]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "Error: not inside a git repository" >&2
        exit 1
    }
fi

tracker_dir="$repo_root/.tickets-tracker"
if [ ! -d "$tracker_dir" ]; then
    echo "Error: .tickets-tracker directory not found at $tracker_dir" >&2
    exit 1
fi

# ── Ensure .review-events directory exists ─────────────────────────────────
events_dir="$tracker_dir/.review-events"
mkdir -p "$events_dir"

# ── Build JSONL line with schema_version=1 and timestamp ───────────────────
# Generate unique filename: <timestamp>-<random>.jsonl
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
random_suffix=$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase + string.digits, k=8)))")
filename="${timestamp//:/}-${random_suffix}.jsonl"

# Build the final JSONL record: ensure schema_version=1 and timestamp are set
jsonl_line=$(python3 -c "
import json, sys

payload = json.loads(sys.argv[1])
timestamp = sys.argv[2]

# Ensure schema_version and timestamp
payload['schema_version'] = 1
if 'timestamp' not in payload or not payload['timestamp']:
    payload['timestamp'] = timestamp

print(json.dumps(payload, separators=(',', ':')))
" "$json_payload" "$timestamp") || {
    echo "Error: failed to construct JSONL line" >&2
    exit 1
}

# ── Stage temp file (same filesystem as tracker_dir for atomic rename) ─────
staging_temp=$(mktemp "$tracker_dir/.review-event-staging-XXXXXX")
printf '%s\n' "$jsonl_line" > "$staging_temp" || {
    rm -f "$staging_temp"
    echo "Error: failed to write staging temp file" >&2
    exit 1
}

final_path="$events_dir/$filename"
commit_msg="review-event: ${event_type} ${filename}"

# ── Write via _flock_stage_commit (shared infrastructure from ticket-lib.sh) ──
# Override flock timeout for testability (lock-exhaustion tests)
if [ -n "${REVIEW_EVENT_LOCK_TIMEOUT:-}" ]; then
    export FLOCK_STAGE_COMMIT_TIMEOUT="$REVIEW_EVENT_LOCK_TIMEOUT"
fi

flock_exit=0
_flock_stage_commit "$tracker_dir" "$staging_temp" "$final_path" "$commit_msg" || flock_exit=$?

if [ "$flock_exit" -ne 0 ]; then
    rm -f "$staging_temp"
    echo "Error: _flock_stage_commit failed (exit $flock_exit)" >&2
    exit 1
fi

exit 0
