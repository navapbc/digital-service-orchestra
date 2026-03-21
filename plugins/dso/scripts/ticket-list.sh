#!/usr/bin/env bash
# plugins/dso/scripts/ticket-list.sh
# List all tickets by compiling each ticket directory via the reducer.
#
# Usage: ticket-list.sh
#   Outputs a JSON array of compiled ticket states to stdout.
#   Errors go to stderr; exits 0 on success (even if some tickets have errors).
#   Empty tracker outputs [].
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Validate ticket system is initialized ─────────────────────────────────────
if [ ! -d "$TRACKER_DIR" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

# ── Collect all ticket states ─────────────────────────────────────────────────
# Build a newline-delimited list of JSON strings, then assemble via python3.
collected_json=""

for ticket_dir_raw in "$TRACKER_DIR"/*/; do
    # Skip if no subdirs exist (glob returns literal pattern)
    [ -d "$ticket_dir_raw" ] || continue

    # Strip trailing slash so basename and reducer work correctly
    ticket_dir="${ticket_dir_raw%/}"
    ticket_id=$(basename "$ticket_dir")

    # Skip hidden directories
    case "$ticket_id" in
        .*) continue ;;
    esac

    # Run reducer
    local_output=""
    local_exit=0
    local_output=$(python3 "$REDUCER" "$ticket_dir" 2>/dev/null) || local_exit=$?

    if [ "$local_exit" -eq 0 ] && [ -n "$local_output" ]; then
        # Exit 0 with output: include reducer's JSON (could be normal or fsck_needed/error status)
        collected_json="${collected_json}${local_output}"$'\n'
    elif [ "$local_exit" -ne 0 ] && [ -n "$local_output" ]; then
        # Exit non-zero with output: reducer printed error-state JSON (status=error/fsck_needed)
        collected_json="${collected_json}${local_output}"$'\n'
    else
        # Exit non-zero with no output (e.g., no CREATE event, reducer returned None)
        # Construct fallback error-state dict
        fallback=$(python3 -c "
import json, sys
print(json.dumps({'ticket_id': sys.argv[1], 'status': 'error', 'error': 'reducer_failed'}))
" "$ticket_id") || {
            echo "WARNING: failed to build fallback for $ticket_id" >&2
            continue
        }
        collected_json="${collected_json}${fallback}"$'\n'
    fi
done

# ── Assemble into JSON array via python3 ──────────────────────────────────────
python3 -c "
import json, sys

lines = sys.stdin.read().strip().split('\n')
results = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        results.append(json.loads(line))
    except json.JSONDecodeError:
        pass

print(json.dumps(results, ensure_ascii=False))
" <<< "$collected_json"
