#!/usr/bin/env bash
# preconditions-validator.sh
# Validate a PRECONDITIONS event file against the minimal required field set.
# Depth-agnostic: unknown fields are ignored, not rejected (forward-compat contract).
#
# Usage:
#   preconditions-validator.sh <ticket_id> <stage> [--event-file=<path>]
#
# Args:
#   ticket_id    Ticket the preconditions event belongs to (e.g., "epic-abc1")
#   stage        Stage name to filter by (e.g., "brainstorm_complete")
#   --event-file Optional: path to a pre-captured JSON event file.
#                If omitted: auto-locates the most recent *-PRECONDITIONS.json
#                in $TICKETS_TRACKER_DIR/<ticket_id>/ (or repo-root tickets-tracker dir) # tickets-boundary-ok
#                whose gate_name matches <stage>. Exit 2 if none found.
#
# Exit codes:
#   0  — event is valid (all required fields present)
#   1  — event is invalid (missing required fields or not a PRECONDITIONS event)
#   2  — event not found (no --event-file and no live event located)

set -uo pipefail

_PLUGIN_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && cd .. && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
ticket_id_arg=""
stage_arg=""
event_file_arg=""

if [ $# -lt 2 ]; then
    echo "Usage: preconditions-validator.sh <ticket_id> <stage> [--event-file=<path>]" >&2
    exit 1
fi

ticket_id_arg="$1"
stage_arg="$2"
shift 2

while [ $# -gt 0 ]; do
    case "$1" in
        --event-file=*)
            event_file_arg="${1#--event-file=}"; shift ;;
        --event-file)
            event_file_arg="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: preconditions-validator.sh <ticket_id> <stage> [--event-file=<path>]" >&2
            exit 0 ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            exit 1 ;;
        *)
            echo "Error: unexpected argument '$1'" >&2
            exit 1 ;;
    esac
done

# ── Locate event file ─────────────────────────────────────────────────────────
target_file=""

if [ -n "$event_file_arg" ]; then
    if [ ! -f "$event_file_arg" ]; then
        echo "Error: event file not found: $event_file_arg" >&2
        exit 2
    fi
    target_file="$event_file_arg"
else
    # Auto-locate: scan ticket's tracker directory for matching PRECONDITIONS event
    _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
    _TRACKER_DIR="${TICKETS_TRACKER_DIR:-${_REPO_ROOT:+$_REPO_ROOT/.tickets-tracker}}" # tickets-boundary-ok
    _TICKET_DIR="${_TRACKER_DIR}/${ticket_id_arg}"
    if [ -n "$_TRACKER_DIR" ] && [ -d "$_TICKET_DIR" ]; then
        # Find most recent PRECONDITIONS file matching the stage (highest timestamp prefix = most recent)
        target_file=$(
            find "$_TICKET_DIR" -maxdepth 1 -name '*-PRECONDITIONS.json' 2>/dev/null \
            | sort -r \
            | while IFS= read -r f; do
                gate=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('gate_name',''))" "$f" 2>/dev/null) || continue
                if [ "$gate" = "$stage_arg" ]; then
                    echo "$f"
                    break
                fi
            done
        )
    fi
    if [ -z "$target_file" ]; then
        echo "Error: no PRECONDITIONS event found for ticket=${ticket_id_arg} stage=${stage_arg}" >&2
        exit 2
    fi
fi

# ── Core validation (python3 inline) ─────────────────────────────────────────
# Required fields: event_type, gate_name, session_id, worktree_id, tier, timestamp, data
# Forward-compat: unknown/extra fields are ignored (not rejected)
python3 - "$target_file" <<'PYEOF'
import json
import sys

required_fields = ['event_type', 'gate_name', 'session_id', 'worktree_id', 'tier', 'timestamp', 'data']

target = sys.argv[1]

try:
    with open(target, encoding='utf-8') as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError) as e:
    print(f"validation error: could not parse JSON: {e}", file=sys.stderr)
    sys.exit(1)

# Check event_type is PRECONDITIONS
event_type = data.get('event_type', '')
if str(event_type).upper() != 'PRECONDITIONS':
    print(f"validation error: expected event_type=PRECONDITIONS, got {event_type!r}", file=sys.stderr)
    sys.exit(1)

# Check all required fields are present and non-None
missing = [f for f in required_fields if f not in data]
if missing:
    print(f"validation error: missing required fields: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

# Validation passed — unknown fields are silently ignored (depth-agnostic forward-compat)
sys.exit(0)
PYEOF
