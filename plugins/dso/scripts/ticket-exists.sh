#!/usr/bin/env bash
# ticket-exists.sh — O(1) presence check for a ticket in the tracker.
# Exit 0 if ticket exists, exit 1 if not.
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: ticket exists <ticket_id>" >&2
    exit 1
fi

ticket_id="$1"

# Resolve tracker dir without unconditional git subprocess.
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
else
    REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

ticket_dir="$TRACKER_DIR/$ticket_id"

# Check for CREATE (normal) or SNAPSHOT (post-compaction) events.
if [ -d "$ticket_dir" ] && \
   { ls "$ticket_dir/"*-CREATE.json >/dev/null 2>&1 || ls "$ticket_dir/"*-SNAPSHOT.json >/dev/null 2>&1; }; then
    exit 0
fi
exit 1
