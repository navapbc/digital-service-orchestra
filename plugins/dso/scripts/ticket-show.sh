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
    echo "$raw_output" | _TICKET_LLM_FMT="$SCRIPT_DIR/ticket-llm-format.py" python3 -c "
import json, sys, importlib.util, pathlib, os

_mod_path = pathlib.Path(os.environ['_TICKET_LLM_FMT'])
try:
    _spec = importlib.util.spec_from_file_location('ticket_llm_format', _mod_path)
    if _spec is None or _spec.loader is None:
        raise ImportError(f'Cannot load module from {_mod_path}')
    _mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)
    to_llm = _mod.to_llm
except (ImportError, FileNotFoundError, OSError) as _e:
    print(f'ERROR: failed to load ticket-llm-format.py: {_e}', file=sys.stderr)
    sys.exit(1)

state = json.load(sys.stdin)
print(json.dumps(to_llm(state), ensure_ascii=False, separators=(',', ':')))
"
else
    # Default: pretty-print JSON
    echo "$raw_output" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, ensure_ascii=False))"
fi
