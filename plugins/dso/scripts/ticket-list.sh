#!/usr/bin/env bash
# plugins/dso/scripts/ticket-list.sh
# List all tickets by compiling each ticket directory via the reducer.
#
# Usage: ticket-list.sh [--format=<fmt>]
#   Outputs a JSON array of compiled ticket states to stdout (default).
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
#                   comments    → cm (sub-keys: body→b, author→au)
#                   deps        → dp (sub-keys: target_id→tid, relation→r)
#   Errors go to stderr; exits 0 on success (even if some tickets have errors).
#   Empty tracker outputs [] (default) or nothing (llm format).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Parse arguments ──────────────────────────────────────────────────────────
format="default"
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
            exit 1
            ;;
    esac
done

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

# ── Assemble and output ────────────────────────────────────────────────────────
if [ "$format" = "llm" ]; then
    # LLM format: JSONL — one minified ticket per line, shortened keys, stripped nulls/empty lists,
    # and no verbose timestamps (created_at, env_id, and comment timestamps omitted).
    python3 -c "
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

COMMENT_KEY_MAP = {'body': 'b', 'author': 'au'}
COMMENT_OMIT = {'timestamp'}
DEP_KEY_MAP = {'target_id': 'tid', 'relation': 'r'}
DEP_OMIT = {'link_uuid'}

def shorten_comment(c):
    if not isinstance(c, dict):
        return c
    return {COMMENT_KEY_MAP.get(k, k): v for k, v in c.items() if k not in COMMENT_OMIT and v is not None}

def shorten_dep(d):
    if not isinstance(d, dict):
        return d
    return {DEP_KEY_MAP.get(k, k): v for k, v in d.items() if k not in DEP_OMIT and v is not None}

def to_llm(state):
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
    return out

lines = sys.stdin.read().strip().split('\n')
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        print(json.dumps(to_llm(obj), ensure_ascii=False, separators=(',', ':')))
    except json.JSONDecodeError as e:
        print(f'WARNING: skipping malformed JSON line: {e}', file=sys.stderr)
" <<< "$collected_json"
else
    # Default: JSON array
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
    except json.JSONDecodeError as e:
        print(f'WARNING: skipping malformed JSON line: {e}', file=sys.stderr)

print(json.dumps(results, ensure_ascii=False))
" <<< "$collected_json"
fi
