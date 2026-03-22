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

# Allow tests to inject a custom tracker directory via TICKETS_TRACKER_DIR env var.
# When GIT_DIR is set (e.g., in tests), derive REPO_ROOT from its parent to avoid
# requiring an actual git repository at that path.
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
elif [ -n "${GIT_DIR:-}" ]; then
    REPO_ROOT="$(dirname "$GIT_DIR")"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
else
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

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
    _TICKET_LLM_FMT="$SCRIPT_DIR/ticket-llm-format.py" python3 -c "
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
    # Also emit a passive aggregate health warning to stderr when unresolved bridge alerts exist.
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

alerted_count = sum(
    1 for t in results
    if any(not a.get('resolved', False) for a in t.get('bridge_alerts', []))
)
if alerted_count > 0:
    print(
        f'WARNING: {alerted_count} ticket(s) have unresolved bridge alerts. Run: ticket bridge-status for details.',
        file=sys.stderr,
    )
" <<< "$collected_json"
fi
