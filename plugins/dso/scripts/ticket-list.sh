#!/usr/bin/env bash
# ticket-list.sh
# List all tickets by compiling each ticket directory via the reducer.
#
# Usage: ticket-list.sh [--format=<fmt>] [--include-archived] [--type=<type>] [--status=<status>] [--parent=<id>]
#   Outputs a JSON array of compiled ticket states to stdout (default).
#   --include-archived  Include archived tickets in the output (default: excluded).
#   --parent=<id>       Filter to direct children of <id> (matches parent_id field).
#   --format=llm  Outputs JSONL (one minified ticket per line) with shortened keys,
#                 stripped nulls/empty lists, and no verbose timestamps
#                 (created_at and env_id are omitted; comment timestamps omitted).
#                 Key mapping:
#                   ticket_id   → id
#                   ticket_type → t
#                   title       → ttl
#                   status      → st
#                   author      → au
#                   parent_id   → pid
#                   priority    → pr
#                   assignee    → asn
#                   comments    → cm (sub-keys: body→b, author→au)
#                   tags        → tg
#                   deps        → dp (sub-keys: target_id→tid, relation→r)
#   Errors go to stderr; exits 0 on success (even if some tickets have errors).
#   Empty tracker outputs [] (default) or nothing (llm format).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"

# Allow tests to inject a custom tracker directory via TICKETS_TRACKER_DIR env var.
# When GIT_DIR is set (e.g., in tests), derive REPO_ROOT from its parent to avoid
# requiring an actual git repository at that path.
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
elif [ -n "${GIT_DIR:-}" ]; then
    REPO_ROOT="$(dirname "$GIT_DIR")"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
else
    REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

# ── Parse arguments ──────────────────────────────────────────────────────────
format="default"
include_archived=""
filter_type=""
filter_status=""
filter_parent=""
for arg in "$@"; do
    case "$arg" in
        --format=llm)
            format="llm"
            ;;
        --format=*)
            echo "Error: unsupported format '${arg#--format=}'. Supported: llm" >&2
            exit 1
            ;;
        --include-archived)
            include_archived="true"
            ;;
        --type=*)
            filter_type="${arg#--type=}"
            ;;
        --status=*)
            filter_status="${arg#--status=}"
            ;;
        --parent=*)
            filter_parent="${arg#--parent=}"
            ;;
        --help|-h)
            echo "Usage: ticket-list.sh [--format=llm] [--include-archived] [--type=<type>] [--status=<status>] [--parent=<id>]" >&2
            echo "  --format=llm       Output JSONL with shortened keys" >&2
            echo "  --include-archived  Include archived tickets" >&2
            echo "  --type=<type>      Filter by ticket type (bug, epic, story, task)" >&2
            echo "  --status=<status>  Filter by status (open, in_progress, closed; comma-separated for multi)" >&2
            echo "  --parent=<id>      Filter to direct children of <id> (matches parent_id)" >&2
            exit 0
            ;;
        -*)
            echo "Error: unknown option '$arg'" >&2
            exit 1
            ;;
    esac
done

# ── Validate ticket system is initialized ─────────────────────────────────────
if [ ! -d "$TRACKER_DIR" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

# ── Assemble and output ────────────────────────────────────────────────────────
if [ "$format" = "llm" ]; then
    # LLM format: JSONL — one minified ticket per line, shortened keys, stripped nulls/empty lists,
    # and no verbose timestamps (created_at, env_id, and comment timestamps omitted).
    # Single-process: reduce → filter → to_llm (no subprocess pipeline).
    _TRACKER_DIR="$TRACKER_DIR" _INCLUDE_ARCHIVED="$include_archived" \
    _TYPE_FILTER="$filter_type" _STATUS_FILTER="$filter_status" \
    _PARENT_FILTER="$filter_parent" \
    _SCRIPT_DIR="$SCRIPT_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_all_tickets
from ticket_reducer.llm_format import to_llm

tracker_dir = os.environ['_TRACKER_DIR']
include_archived = os.environ.get('_INCLUDE_ARCHIVED', '') == 'true'
type_filter = os.environ.get('_TYPE_FILTER', '')
status_filter = os.environ.get('_STATUS_FILTER', '')
parent_filter = os.environ.get('_PARENT_FILTER', '')

results = reduce_all_tickets(tracker_dir, exclude_archived=not include_archived)
# Exclude error/fsck_needed tickets unless explicitly requested via --status (d145-e1a9)
if status_filter not in ('error', 'fsck_needed'):
    results = [t for t in results if t.get('status') not in ('error', 'fsck_needed')]
if type_filter:
    results = [t for t in results if t.get('ticket_type') == type_filter]
if status_filter:
    status_values = {s.strip() for s in status_filter.split(',')}
    results = [t for t in results if t.get('status') in status_values]
if parent_filter:
    results = [t for t in results if t.get('parent_id') == parent_filter]
for t in results:
    print(json.dumps(to_llm(t), ensure_ascii=False, separators=(',', ':')))
"
else
    # Default: JSON array — reduce, filter, and emit in a single process.
    # Also emit a passive aggregate health warning to stderr when unresolved bridge alerts exist.
    _TRACKER_DIR="$TRACKER_DIR" _INCLUDE_ARCHIVED="$include_archived" \
    _TYPE_FILTER="$filter_type" _STATUS_FILTER="$filter_status" \
    _PARENT_FILTER="$filter_parent" \
    _SCRIPT_DIR="$SCRIPT_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_all_tickets

tracker_dir = os.environ['_TRACKER_DIR']
include_archived = os.environ.get('_INCLUDE_ARCHIVED', '') == 'true'
type_filter = os.environ.get('_TYPE_FILTER', '')
status_filter = os.environ.get('_STATUS_FILTER', '')
parent_filter = os.environ.get('_PARENT_FILTER', '')

results = reduce_all_tickets(tracker_dir, exclude_archived=not include_archived)
# Exclude error/fsck_needed tickets unless explicitly requested via --status (d145-e1a9)
if status_filter not in ('error', 'fsck_needed'):
    results = [t for t in results if t.get('status') not in ('error', 'fsck_needed')]
if type_filter:
    results = [t for t in results if t.get('ticket_type') == type_filter]
if status_filter:
    status_values = {s.strip() for s in status_filter.split(',')}
    results = [t for t in results if t.get('status') in status_values]
if parent_filter:
    results = [t for t in results if t.get('parent_id') == parent_filter]
print(json.dumps(results, ensure_ascii=False))

alerted_count = sum(
    1 for t in results
    if any(not a.get('resolved', False) for a in t.get('bridge_alerts', []))
)
if alerted_count > 0:
    print(
        f'WARNING: {alerted_count} ticket(s) have unresolved bridge alerts. Run: ticket bridge-status for details.',
        file=sys.stderr,
    )
"
fi
