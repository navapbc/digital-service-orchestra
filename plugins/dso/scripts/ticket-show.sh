#!/usr/bin/env bash
# plugins/dso/scripts/ticket-show.sh
# Show compiled state for a ticket by invoking the event reducer.
#
# Usage: ticket show <ticket_id>
#   ticket_id: ID of the ticket to show
#
# Outputs the compiled ticket state as pretty-printed JSON to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket show <ticket_id>" >&2
    exit 1
}

# ── Validate arguments ───────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    _usage
fi

ticket_id="$1"

# ── Verify ticket directory exists ────────────────────────────────────────────
if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
    echo "Error: Ticket '$ticket_id' not found" >&2
    exit 1
fi

# ── Invoke reducer ────────────────────────────────────────────────────────────
raw_output=$(python3 "$SCRIPT_DIR/ticket-reducer.py" "$TRACKER_DIR/$ticket_id") || {
    echo "Error: ticket '$ticket_id' has no CREATE event" >&2
    exit 1
}

# ── Pretty-print JSON ────────────────────────────────────────────────────────
echo "$raw_output" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))"
