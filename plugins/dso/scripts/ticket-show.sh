#!/usr/bin/env bash
# plugins/dso/scripts/ticket-show.sh
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
#                   comments    → cm
#                   deps        → dp
#                   conflicts   → cf
#
# Outputs the compiled ticket state to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

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
raw_output=$(python3 "$SCRIPT_DIR/ticket-reducer.py" "$TRACKER_DIR/$ticket_id") || {
    echo "Error: ticket '$ticket_id' has no CREATE event" >&2
    exit 1
}

# ── Format and output ────────────────────────────────────────────────────────
if [ "$format" = "llm" ]; then
    # LLM format: minified JSON with shortened keys, stripped nulls/empty lists,
    # and no verbose timestamps (created_at, env_id, and comment timestamps omitted).
    # Key mapping: ticket_id→id, ticket_type→t, title→ttl, status→st,
    #              author→au, parent_id→pid,
    #              comments→cm (comment sub-keys: body→b, author→au),
    #              deps→dp (dep sub-keys: target_id→tid, relation→r)
    echo "$raw_output" | python3 -c "
import json, sys

KEY_MAP = {
    'ticket_id': 'id',
    'ticket_type': 't',
    'title': 'ttl',
    'status': 'st',
    'author': 'au',
    'parent_id': 'pid',
    'comments': 'cm',
    'deps': 'dp',
    'conflicts': 'cf',
}

# Fields omitted from LLM format (verbose timestamps / system metadata)
OMIT_KEYS = {'created_at', 'env_id'}

# Comment: keep only body and author (omit timestamp — not useful for LLM)
COMMENT_KEY_MAP = {
    'body': 'b',
    'author': 'au',
}
COMMENT_OMIT = {'timestamp'}

DEP_KEY_MAP = {
    'target_id': 'tid',
    'relation': 'r',
}
DEP_OMIT = {'link_uuid'}

def shorten_comment(c):
    if not isinstance(c, dict):
        return c
    out = {}
    for k, v in c.items():
        if k in COMMENT_OMIT or v is None:
            continue
        out[COMMENT_KEY_MAP.get(k, k)] = v
    return out

def shorten_dep(d):
    if not isinstance(d, dict):
        return d
    out = {}
    for k, v in d.items():
        if k in DEP_OMIT or v is None:
            continue
        out[DEP_KEY_MAP.get(k, k)] = v
    return out

state = json.load(sys.stdin)
out = {}
for k, v in state.items():
    if k in OMIT_KEYS:
        continue
    if v is None:
        continue
    if isinstance(v, list) and len(v) == 0:
        continue
    short_k = KEY_MAP.get(k, k)
    if k == 'comments':
        v = [shorten_comment(c) for c in v]
    elif k == 'deps':
        v = [shorten_dep(d) for d in v]
    out[short_k] = v
print(json.dumps(out, ensure_ascii=False, separators=(',', ':')))
"
else
    # Default: pretty-print JSON
    echo "$raw_output" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))"
fi
