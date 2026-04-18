#!/usr/bin/env bash
# ticket-show.sh
# Show compiled state for a ticket by invoking the event reducer.
#
# Usage: ticket show [--format=<fmt>] <ticket_id>
#   ticket_id: ID of the ticket to show
#   --format=llm  Minified single-line JSON with shortened keys, stripped nulls,
#                 and no verbose timestamps (created_at and env_id are omitted entirely).
#                 Key mapping:
#                   ticket_id   → id
#                   ticket_type → t
#                   title       → ttl
#                   status      → st
#                   author      → au
#                   parent_id   → pid
#                   priority    → pr
#                   assignee    → asn
#                   comments    → cm
#                   deps        → dp
#                   conflicts   → cf
#
# Outputs the compiled ticket state to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Unset git hook env vars so git commands target the correct repo.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

# Allow tests to inject a custom tracker directory via TICKETS_TRACKER_DIR env var.
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
else
    REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket show [--format=llm] <ticket_id>" >&2
    exit 1
}

# ── Parse arguments ──────────────────────────────────────────────────────────
format="default"
ticket_id=""

for arg in "$@"; do
    case "$arg" in
        --format=llm)
            format="llm"
            ;;
        --format=*)
            echo "Error: unsupported format '${arg#--format=}'. Supported: llm" >&2
            exit 1
            ;;
        -*)
            echo "Error: unknown option '$arg'" >&2
            _usage
            ;;
        *)
            if [ -z "$ticket_id" ]; then
                ticket_id="$arg"
            fi
            ;;
    esac
done

if [ -z "$ticket_id" ]; then
    _usage
fi

# ── Verify ticket directory exists ────────────────────────────────────────────
if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
    echo "Error: Ticket '$ticket_id' not found" >&2
    exit 1
fi

# ── Invoke reducer ────────────────────────────────────────────────────────────
# Single python3 process handles reduce + format (no subprocess pipeline).
_TICKET_DIR="$TRACKER_DIR/$ticket_id" _TICKET_ID="$ticket_id" \
_FORMAT="$format" _SCRIPT_DIR="$SCRIPT_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_ticket

ticket_dir = os.environ['_TICKET_DIR']
ticket_id = os.environ['_TICKET_ID']
fmt = os.environ.get('_FORMAT', 'default')

state = reduce_ticket(ticket_dir)
if state is None:
    print(f'Error: ticket \"{ticket_id}\" has no CREATE or SNAPSHOT event', file=sys.stderr)
    sys.exit(1)
if state.get('status') in ('error', 'fsck_needed'):
    print(json.dumps(state, ensure_ascii=False))
    print(f'Error: ticket \"{ticket_id}\" has status \"{state[\"status\"]}\"', file=sys.stderr)
    sys.exit(1)

if fmt == 'llm':
    from ticket_reducer.llm_format import to_llm
    print(json.dumps(to_llm(state), ensure_ascii=False, separators=(',', ':')))
else:
    print(json.dumps(state, indent=2, ensure_ascii=False))
    alerts = state.get('bridge_alerts', [])
    unresolved = sum(1 for a in alerts if not a.get('resolved', False))
    if unresolved > 0:
        print(
            f'WARNING: ticket {ticket_id} has {unresolved} unresolved bridge alert(s).'
            ' Run: ticket bridge-status for details.',
            file=sys.stderr,
        )
" || exit $?
