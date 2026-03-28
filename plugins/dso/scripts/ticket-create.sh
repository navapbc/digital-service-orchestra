#!/usr/bin/env bash
# plugins/dso/scripts/ticket-create.sh
# Create a new ticket with a CREATE event committed to the tickets branch.
#
# Usage: ticket-create.sh <ticket_type> <title> [--parent <id>] [--priority <n>] [--assignee <name>]
#   ticket_type: one of bug, epic, story, task
#   title: non-empty string
#   --parent: optional parent ticket ID (must exist in .tickets-tracker/)
#   --priority: optional priority (0-4; 0=critical, 4=backlog; default: 2)
#   --assignee: optional assignee name (defaults to git config user.name)
#
# Outputs the created ticket ID to stdout (only the ID — no other output).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/dso/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket create <ticket_type> <title> [--parent <id>] [--priority <n>] [--assignee <name>] [--description <text>]" >&2
    echo "  ticket_type: bug | epic | story | task" >&2
    echo "  title: non-empty string" >&2
    echo "  --parent: optional parent ticket ID" >&2
    echo "  --priority: 0-4 (0=critical, 4=backlog; default: 2)" >&2
    echo "  --assignee: assignee name (default: git config user.name)" >&2
    echo "  --description, -d: optional description text" >&2
    exit 1
}

# ── Validate arguments ───────────────────────────────────────────────────────
if [ $# -lt 2 ]; then
    _usage
fi

ticket_type="$1"
title="$2"
shift 2

# Parse remaining args: support both positional parent_id and --parent <id>
parent_id=""
priority="2"  # REVIEW-DEFENSE: default P2 is intentional — user-requested behavior change so all tickets have a priority
assignee=""
description=""
while [ $# -gt 0 ]; do
    case "$1" in
        --parent)
            parent_id="$2"
            shift 2
            ;;
        --parent=*)
            parent_id="${1#--parent=}"
            shift
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --priority=*)
            priority="${1#--priority=}"
            shift
            ;;
        --assignee)
            assignee="$2"
            shift 2
            ;;
        --assignee=*)
            assignee="${1#--assignee=}"
            shift
            ;;
        --description)
            description="$2"
            shift 2
            ;;
        --description=*)
            description="${1#--description=}"
            shift
            ;;
        -d)
            description="$2"
            shift 2
            ;;
        *)
            # Positional: treat as parent_id (backward-compatible)
            parent_id="$1"
            shift
            ;;
    esac
done

# Default assignee to git user.name if not provided
if [ -z "$assignee" ]; then
    assignee=$(git config user.name 2>/dev/null || echo "")
fi

# Validate ticket_type
case "$ticket_type" in
    bug|epic|story|task) ;;
    *)
        echo "Error: invalid ticket type '$ticket_type'. Must be one of: bug, epic, story, task" >&2
        exit 1
        ;;
esac

# Validate title is non-empty
if [ -z "$title" ]; then
    echo "Error: title must be non-empty" >&2
    exit 1
fi

# ── Validate ticket system is initialized ─────────────────────────────────────
if [ ! -f "$TRACKER_DIR/.env-id" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

# ── Validate parent_id exists if provided ─────────────────────────────────────
if [ -n "$parent_id" ]; then
    if [ ! -d "$TRACKER_DIR/$parent_id" ]; then
        echo "Error: parent ticket '$parent_id' does not exist" >&2
        exit 1
    fi
    # Verify it has a CREATE or SNAPSHOT event (SNAPSHOT replaces CREATE after compaction)
    if ! find "$TRACKER_DIR/$parent_id" -maxdepth 1 \( -name '*-CREATE.json' -o -name '*-SNAPSHOT.json' \) ! -name '.*' 2>/dev/null | grep -q .; then
        echo "Error: parent ticket '$parent_id' has no CREATE or SNAPSHOT event" >&2
        exit 1
    fi
    # Guard: cannot create a child under a closed parent
    parent_status=$(ticket_read_status "$TRACKER_DIR" "$parent_id") || {
        echo "Error: could not read status for parent ticket '$parent_id'" >&2
        exit 1
    }
    if [ "$parent_status" = "closed" ]; then
        echo "Error: cannot create child of closed ticket '$parent_id'. Reopen the parent first with: ticket transition $parent_id closed open" >&2
        exit 1
    fi
fi

# ── Generate ticket ID and event metadata ─────────────────────────────────────
env_id=$(cat "$TRACKER_DIR/.env-id")
author=$(git config user.name 2>/dev/null || echo "Unknown")

# Generate collision-resistant short ID + full UUID4 + timestamp via single python3 call
event_meta=$(python3 -c "
import uuid, time
u = str(uuid.uuid4()).replace('-', '')
ticket_id = u[:4] + '-' + u[4:8]
event_uuid = str(uuid.uuid4())
timestamp = int(time.time())
print(ticket_id)
print(event_uuid)
print(timestamp)
")

ticket_id=$(echo "$event_meta" | sed -n '1p')
event_uuid=$(echo "$event_meta" | sed -n '2p')
timestamp=$(echo "$event_meta" | sed -n '3p')

# ── Build CREATE event JSON via python3 ───────────────────────────────────────
temp_event=$(mktemp "$TRACKER_DIR/.tmp-create-XXXXXX")

python3 -c "
import json, sys

data = {
    'ticket_type': sys.argv[5],
    'title': sys.argv[6],
    'parent_id': sys.argv[7] if sys.argv[7] else '',
    'description': sys.argv[10]
}
if sys.argv[8]:
    data['priority'] = int(sys.argv[8])
if sys.argv[9]:
    data['assignee'] = sys.argv[9]

event = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'CREATE',
    'env_id': sys.argv[3],
    'author': sys.argv[4],
    'data': data
}

with open(sys.argv[11], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$timestamp" "$event_uuid" "$env_id" "$author" "$ticket_type" "$title" "$parent_id" "$priority" "$assignee" "$description" "$temp_event" || {
    rm -f "$temp_event"
    echo "Error: failed to build CREATE event JSON" >&2
    exit 1
}

# ── Write and commit via ticket-lib.sh ────────────────────────────────────────
write_commit_event "$ticket_id" "$temp_event" || {
    rm -f "$temp_event"
    echo "Error: failed to write and commit CREATE event" >&2
    exit 1
}

# Clean up temp file (write_commit_event stages it, but original temp may remain)
rm -f "$temp_event"

# ── Output ticket ID ─────────────────────────────────────────────────────────
echo "$ticket_id"
