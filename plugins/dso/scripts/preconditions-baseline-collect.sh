#!/usr/bin/env bash
# preconditions-baseline-collect.sh
# Collect the restart-rate baseline for an epic by counting REPLAN_TRIGGER
# COMMENT events in .tickets-tracker/<epic_id>/ and writing a PRECONDITIONS
# event with gate_name=restart_rate_baseline.
#
# Usage:
#   preconditions-baseline-collect.sh <epic_id> <session_id> [worktree_id]
#
# Required:
#   epic_id     Ticket/epic to collect the baseline for (positional $1)
#   session_id  Session identifier (positional $2)
#
# Optional:
#   worktree_id Branch identifier (positional $3; defaults to current git branch)
#
# Exit codes:
#   0  — success: PRECONDITIONS event written
#   1  — error: missing arguments, tracker not initialized, or write failure

set -euo pipefail

EPIC_ID="${1:-}"
SESSION_ID="${2:-}"

if [[ -z "$EPIC_ID" || -z "$SESSION_ID" ]]; then
    echo "Usage: $0 <epic_id> <session_id> [worktree_id]" >&2
    exit 1
fi

WORKTREE_ID="${3:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the shared flock library
# shellcheck source=${_PLUGIN_ROOT}/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="${TICKETS_TRACKER_DIR:-$REPO_ROOT/.tickets-tracker}"

# ── Count REPLAN_TRIGGER COMMENT events ─────────────────────────────────────
RESTART_COUNT=$(python3 -c "
import json, os, sys, glob

tracker_dir = sys.argv[1]
epic_id     = sys.argv[2]
ticket_dir  = os.path.join(tracker_dir, epic_id)

count = 0
for f in glob.glob(os.path.join(ticket_dir, '*-COMMENT.json')):
    try:
        with open(f, encoding='utf-8') as fh:
            d = json.load(fh)
        body = d.get('data', {}).get('body', '')
        if body.startswith('REPLAN_TRIGGER:'):
            count += 1
    except Exception:
        pass
print(count)
" "$TRACKER_DIR" "$EPIC_ID")

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATA_JSON="{\"restart_count\": $RESTART_COUNT, \"timestamp\": \"$TIMESTAMP\"}"

_write_preconditions \
    "$EPIC_ID" \
    "restart_rate_baseline" \
    "$SESSION_ID" \
    "$WORKTREE_ID" \
    "minimal" \
    "$DATA_JSON"
