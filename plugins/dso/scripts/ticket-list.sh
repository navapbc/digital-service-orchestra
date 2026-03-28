#!/usr/bin/env bash
# plugins/dso/scripts/ticket-list.sh
# List all tickets by compiling each ticket directory via the reducer.
#
# Usage: ticket-list.sh [--format=<fmt>] [--include-archived]
#   Outputs a JSON array of compiled ticket states to stdout (default).
#   --include-archived  Include archived tickets in the output (default: excluded).
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

# ── Batch-reduce all tickets ──────────────────────────────────────────────────
batch_output=""
batch_exit=0
if [ -n "$include_archived" ]; then
    batch_output=$(python3 "$REDUCER" --batch "$TRACKER_DIR" 2>/dev/null) || batch_exit=$?
else
    batch_output=$(python3 "$REDUCER" --batch --exclude-archived "$TRACKER_DIR" 2>/dev/null) || batch_exit=$?
fi

if [ "$batch_exit" -ne 0 ] && [ -z "$batch_output" ]; then
    echo "Error: batch reducer failed (exit $batch_exit) with no output" >&2
    exit 1
fi

# ── Assemble and output ────────────────────────────────────────────────────────
if [ "$format" = "llm" ]; then
    # LLM format: JSONL — one minified ticket per line, shortened keys, stripped nulls/empty lists,
    # and no verbose timestamps (created_at, env_id, and comment timestamps omitted).
    # Convert JSON array to newline-delimited JSON objects, then pipe through LLM formatter.
    echo "$batch_output" \
        | python3 -c "import json,sys; [print(json.dumps(t)) for t in json.loads(sys.stdin.read())]" \
        | _TICKET_LLM_FMT="$SCRIPT_DIR/ticket-llm-format.py" python3 -c "
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

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        print(json.dumps(to_llm(obj), ensure_ascii=False, separators=(',', ':')))
    except json.JSONDecodeError as e:
        print(f'WARNING: skipping malformed JSON line: {e}', file=sys.stderr)
"
else
    # Default: JSON array — batch output is already a JSON array; emit directly.
    # Also emit a passive aggregate health warning to stderr when unresolved bridge alerts exist.
    python3 -c "
import json, sys

results = json.loads(sys.stdin.read())
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
" <<< "$batch_output"
fi
