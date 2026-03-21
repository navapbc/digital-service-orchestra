#!/usr/bin/env bash
# plugins/dso/scripts/ticket-comment.sh
# Append a COMMENT event to a ticket and auto-commit it.
#
# Usage: ticket-comment.sh <ticket_id> <body>
#   ticket_id: the ticket directory name (e.g., w21-ablv)
#   body: non-empty comment text
#
# Ghost prevention: verifies CREATE event exists before writing COMMENT.
# Exits 0 on success, 1 on validation failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket comment <ticket_id> <body>" >&2
    echo "  ticket_id: ticket directory name" >&2
    echo "  body: non-empty comment text" >&2
    exit 1
}

# ── Step 1: Validate arguments ───────────────────────────────────────────────
if [ $# -lt 2 ]; then
    _usage
fi

ticket_id="$1"
body="$2"

# Body must be non-empty
if [ -z "$body" ]; then
    echo "Error: comment body must be non-empty" >&2
    exit 1
fi

# ── Validate ticket system is initialized ─────────────────────────────────────
if [ ! -f "$TRACKER_DIR/.env-id" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

# ── Step 2: Ghost check ─────────────────────────────────────────────────────
if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
    echo "Error: ticket '$ticket_id' does not exist" >&2
    exit 1
fi

if ! find "$TRACKER_DIR/$ticket_id" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | grep -q .; then
    echo "Error: ticket $ticket_id has no CREATE event" >&2
    exit 1
fi

# ── Step 3: Build COMMENT event JSON via python3 ────────────────────────────
env_id=$(cat "$TRACKER_DIR/.env-id")
author=$(git config user.name 2>/dev/null || echo "Unknown")

temp_event=$(mktemp "$TRACKER_DIR/.tmp-comment-XXXXXX")

python3 -c "
import json, sys, time, uuid

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'COMMENT',
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': {
        'body': sys.argv[3]
    }
}

with open(sys.argv[4], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$body" "$temp_event" || {
    rm -f "$temp_event"
    echo "Error: failed to build COMMENT event JSON" >&2
    exit 1
}

# ── Step 4: Write and commit via ticket-lib.sh ──────────────────────────────
write_commit_event "$ticket_id" "$temp_event" || {
    rm -f "$temp_event"
    echo "Error: failed to write and commit COMMENT event" >&2
    exit 1
}

# Clean up temp file
rm -f "$temp_event"

exit 0
