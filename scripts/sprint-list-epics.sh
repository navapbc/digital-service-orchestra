#!/usr/bin/env bash
# sprint-list-epics.sh — List unblocked epics for /sprint Phase 1.
#
# Consolidates the multi-command epic discovery sequence into a single
# deterministic script call with minimal output.
#
# Usage:
#   sprint-list-epics.sh           # List unblocked open epics, sorted by priority
#   sprint-list-epics.sh --all     # Include blocked epics (marked with BLOCKED)
#
# Output: One line per epic, tab-separated:
#   <id>\tP*\t<title>                          (in-progress epics, listed first — P* replaces priority)
#   <id>\tP<priority>\t<title>                 (unblocked open epics)
#
# Blocked epics (with --all) are appended after unblocked, prefixed:
#   BLOCKED\t<id>\tP<priority>\t<title>
#
# Exit codes:
#   0 — At least one unblocked epic found
#   1 — No open epics exist
#   2 — Open epics exist but all are blocked (details on stderr)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared tk availability helper
TK="${TK:-$SCRIPT_DIR/tk}"

source "$SCRIPT_DIR/lib/require-tk.sh"
require_tk

show_all=false
[[ "${1:-}" == "--all" ]] && show_all=true

REPO_ROOT=$(git rev-parse --show-toplevel)
TICKETS_DIR="${TICKETS_DIR:-$REPO_ROOT/.tickets}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# ---------------------------------------------------------------------------
# Collect in-progress epics by scanning .tickets/ for type=epic, status=in_progress.
# tk has no query subcommand; direct filesystem scan is the canonical approach.
# ---------------------------------------------------------------------------
in_progress_json="["
first_ip=true
if [ -d "$TICKETS_DIR" ]; then
    for ticket_file in "$TICKETS_DIR"/*.md; do
        [ -f "$ticket_file" ] || continue
        file_type=$(grep -m1 '^type:' "$ticket_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '\r') || true
        file_status=$(grep -m1 '^status:' "$ticket_file" 2>/dev/null | sed 's/^status:[[:space:]]*//' | tr -d '\r') || true
        [ "$file_type" = "epic" ] || continue
        [ "$file_status" = "in_progress" ] || continue
        epic_id=$(basename "$ticket_file" .md)
        epic_raw=$("$TK" show "$epic_id" 2>/dev/null || true)
        if [ -n "$epic_raw" ]; then
            epic_title=$(echo "$epic_raw" | grep -m1 '^title:' | sed 's/^title:[[:space:]]*//' | tr -d '\r') || true
            # Fallback: parse '# Title' markdown header if no title: in frontmatter
            if [ -z "$epic_title" ]; then
                epic_title=$(echo "$epic_raw" | grep -m1 '^# ' | sed 's/^# //' | tr -d '\r') || true
            fi
            epic_priority=$(echo "$epic_raw" | grep -m1 '^priority:' | sed 's/^priority:[[:space:]]*//' | tr -d '\r') || true
        else
            epic_title=$(grep -m1 '^title:' "$ticket_file" | sed 's/^title:[[:space:]]*//' | tr -d '\r') || true
            if [ -z "$epic_title" ]; then
                epic_title=$(grep -m1 '^# ' "$ticket_file" | sed 's/^# //' | tr -d '\r') || true
            fi
            epic_priority=$(grep -m1 '^priority:' "$ticket_file" | sed 's/^priority:[[:space:]]*//' | tr -d '\r') || true
        fi
        [ "$first_ip" = true ] || in_progress_json+=","
        first_ip=false
        in_progress_json+="{\"id\":\"$epic_id\",\"title\":\"${epic_title:-untitled}\",\"priority\":${epic_priority:-4},\"status\":\"in_progress\"}"
    done
fi
in_progress_json+="]"
echo "$in_progress_json" >"$tmpdir/in_progress.json"

# ---------------------------------------------------------------------------
# Collect unblocked open epics via tk ready.
# tk ready prints lines of the form: <id> [P<n>][open] - <title>
# We parse this output into a JSON array for the Python formatter.
# ---------------------------------------------------------------------------
ready_raw=$("$TK" ready 2>/dev/null || true)
ready_json="["
first_ready=true
while IFS= read -r line; do
    [ -n "$line" ] || continue
    epic_id=$(echo "$line" | awk '{print $1}')
    [ -n "$epic_id" ] || continue
    # Filter: only include epics (check ticket file type field)
    ticket_file="$TICKETS_DIR/$epic_id.md"
    if [ -f "$ticket_file" ]; then
        item_type=$(grep -m1 '^type:' "$ticket_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '\r') || true
        [ "$item_type" = "epic" ] || continue
    else
        continue
    fi
    # Parse priority from [P<n>] token
    epic_priority=$(echo "$line" | grep -oE '\[P[0-9]+\]' | head -1 | tr -d '[]P')
    [ -n "$epic_priority" ] || epic_priority=4
    # Parse title after last ' - ' separator
    epic_title=$(echo "$line" | sed 's/.*] - //')
    [ "$first_ready" = true ] || ready_json+=","
    first_ready=false
    ready_json+="{\"id\":\"$epic_id\",\"title\":\"${epic_title:-untitled}\",\"priority\":${epic_priority},\"status\":\"open\"}"
done <<< "$ready_raw"
ready_json+="]"
echo "$ready_json" >"$tmpdir/ready.json"

# ---------------------------------------------------------------------------
# Collect blocked epics via tk blocked (used for --all display and exit-2 detection).
# tk blocked prints lines of the form: <id> [P<n>][open] - <title>
# ---------------------------------------------------------------------------
blocked_raw=$("$TK" blocked 2>/dev/null || true)
blocked_json="["
first_blocked=true
while IFS= read -r line; do
    [ -n "$line" ] || continue
    epic_id=$(echo "$line" | awk '{print $1}')
    [ -n "$epic_id" ] || continue
    # Filter: only include epics (check ticket file type field)
    ticket_file="$TICKETS_DIR/$epic_id.md"
    if [ -f "$ticket_file" ]; then
        item_type=$(grep -m1 '^type:' "$ticket_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '\r') || true
        [ "$item_type" = "epic" ] || continue
    else
        continue
    fi
    epic_priority=$(echo "$line" | grep -oE '\[P[0-9]+\]' | head -1 | tr -d '[]P')
    [ -n "$epic_priority" ] || epic_priority=4
    epic_title=$(echo "$line" | sed 's/.*] - //')
    [ "$first_blocked" = true ] || blocked_json+=","
    first_blocked=false
    blocked_json+="{\"id\":\"$epic_id\",\"title\":\"${epic_title:-untitled}\",\"priority\":${epic_priority},\"status\":\"open\"}"
done <<< "$blocked_raw"
blocked_json+="]"
echo "$blocked_json" >"$tmpdir/blocked.json"

# ---------------------------------------------------------------------------
# Single retry: re-run collection if all results empty (guards against
# transient filesystem state; tk is file-per-issue so no hash mismatch,
# but a brief retry keeps parity with original robustness intent).
# ---------------------------------------------------------------------------
if python3 -c "
import json, sys
for f in ['$tmpdir/in_progress.json', '$tmpdir/ready.json', '$tmpdir/blocked.json']:
    with open(f) as fh:
        if json.load(fh):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    : # At least one list has data — proceed
else
    # One retry — re-scan .tickets/ directly (tk has no query subcommand)
    in_progress_json="["
    first_ip=true
    if [ -d "$TICKETS_DIR" ]; then
        for ticket_file in "$TICKETS_DIR"/*.md; do
            [ -f "$ticket_file" ] || continue
            file_type=$(grep -m1 '^type:' "$ticket_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '\r') || true
            file_status=$(grep -m1 '^status:' "$ticket_file" 2>/dev/null | sed 's/^status:[[:space:]]*//' | tr -d '\r') || true
            [ "$file_type" = "epic" ] || continue
            [ "$file_status" = "in_progress" ] || continue
            epic_id=$(basename "$ticket_file" .md)
            epic_raw=$("$TK" show "$epic_id" 2>/dev/null || true)
            if [ -n "$epic_raw" ]; then
                epic_title=$(echo "$epic_raw" | grep -m1 '^title:' | sed 's/^title:[[:space:]]*//' | tr -d '\r') || true
                if [ -z "$epic_title" ]; then
                    epic_title=$(echo "$epic_raw" | grep -m1 '^# ' | sed 's/^# //' | tr -d '\r') || true
                fi
                epic_priority=$(echo "$epic_raw" | grep -m1 '^priority:' | sed 's/^priority:[[:space:]]*//' | tr -d '\r') || true
            else
                epic_title=$(grep -m1 '^title:' "$ticket_file" | sed 's/^title:[[:space:]]*//' | tr -d '\r') || true
                if [ -z "$epic_title" ]; then
                    epic_title=$(grep -m1 '^# ' "$ticket_file" | sed 's/^# //' | tr -d '\r') || true
                fi
                epic_priority=$(grep -m1 '^priority:' "$ticket_file" | sed 's/^priority:[[:space:]]*//' | tr -d '\r') || true
            fi
            [ "$first_ip" = true ] || in_progress_json+=","
            first_ip=false
            in_progress_json+="{\"id\":\"$epic_id\",\"title\":\"${epic_title:-untitled}\",\"priority\":${epic_priority:-4},\"status\":\"in_progress\"}"
        done
    fi
    in_progress_json+="]"
    echo "$in_progress_json" >"$tmpdir/in_progress.json"
    ready_raw=$("$TK" ready 2>/dev/null || true)
    ready_json="["
    first_ready=true
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        epic_id=$(echo "$line" | awk '{print $1}')
        [ -n "$epic_id" ] || continue
        # Filter: only include epics
        ticket_file="$TICKETS_DIR/$epic_id.md"
        if [ -f "$ticket_file" ]; then
            item_type=$(grep -m1 '^type:' "$ticket_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '\r') || true
            [ "$item_type" = "epic" ] || continue
        else
            continue
        fi
        epic_priority=$(echo "$line" | grep -oE '\[P[0-9]+\]' | head -1 | tr -d '[]P')
        [ -n "$epic_priority" ] || epic_priority=4
        epic_title=$(echo "$line" | sed 's/.*] - //')
        [ "$first_ready" = true ] || ready_json+=","
        first_ready=false
        ready_json+="{\"id\":\"$epic_id\",\"title\":\"${epic_title:-untitled}\",\"priority\":${epic_priority},\"status\":\"open\"}"
    done <<< "$ready_raw"
    ready_json+="]"
    echo "$ready_json" >"$tmpdir/ready.json"
    blocked_raw=$("$TK" blocked 2>/dev/null || true)
    blocked_json="["
    first_blocked=true
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        epic_id=$(echo "$line" | awk '{print $1}')
        [ -n "$epic_id" ] || continue
        # Filter: only include epics
        ticket_file="$TICKETS_DIR/$epic_id.md"
        if [ -f "$ticket_file" ]; then
            item_type=$(grep -m1 '^type:' "$ticket_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '\r') || true
            [ "$item_type" = "epic" ] || continue
        else
            continue
        fi
        epic_priority=$(echo "$line" | grep -oE '\[P[0-9]+\]' | head -1 | tr -d '[]P')
        [ -n "$epic_priority" ] || epic_priority=4
        epic_title=$(echo "$line" | sed 's/.*] - //')
        [ "$first_blocked" = true ] || blocked_json+=","
        first_blocked=false
        blocked_json+="{\"id\":\"$epic_id\",\"title\":\"${epic_title:-untitled}\",\"priority\":${epic_priority},\"status\":\"open\"}"
    done <<< "$blocked_raw"
    blocked_json+="]"
    echo "$blocked_json" >"$tmpdir/blocked.json"
fi

# ---------------------------------------------------------------------------
# Python formatter: emit output lines and determine exit code.
# ---------------------------------------------------------------------------
SPRINT_TMPDIR="$tmpdir" SPRINT_SHOW_ALL="$show_all" python3 -c "
import json, sys, os

show_all = os.environ.get('SPRINT_SHOW_ALL') == 'true'
tmpdir = os.environ['SPRINT_TMPDIR']

with open(os.path.join(tmpdir, 'in_progress.json')) as f:
    in_progress = json.load(f)

with open(os.path.join(tmpdir, 'ready.json')) as f:
    ready = json.load(f)

with open(os.path.join(tmpdir, 'blocked.json')) as f:
    blocked = json.load(f)

in_progress_ids = {e['id'] for e in in_progress}
ready_ids = {e['id'] for e in ready}

# Deduplicate ready list: skip any already in in_progress
ready_filtered = [e for e in ready if e['id'] not in in_progress_ids]

# selectable = in-progress + unblocked-open
selectable_ids = in_progress_ids | {e['id'] for e in ready_filtered}

if not in_progress and not ready_filtered and not blocked:
    print('No open epics found.', file=sys.stderr)
    sys.exit(1)

# In-progress epics first (P* signals already claimed work)
for e in sorted(in_progress, key=lambda x: x.get('priority', 4)):
    print(f'{e[\"id\"]}\tP*\t{e.get(\"title\", \"\")}')

# Then unblocked open epics
for e in sorted(ready_filtered, key=lambda x: x.get('priority', 4)):
    print(f'{e[\"id\"]}\tP{e.get(\"priority\", 4)}\t{e.get(\"title\", \"\")}')

if show_all:
    for e in sorted(blocked, key=lambda x: x.get('priority', 4)):
        if e['id'] not in selectable_ids:
            print(f'BLOCKED\t{e[\"id\"]}\tP{e.get(\"priority\", 4)}\t{e.get(\"title\", \"\")}')

# Exit code logic:
#   0 — at least one unblocked epic (in-progress or ready)
#   2 — open epics exist but all are blocked
#   1 — no open epics at all
if in_progress or ready_filtered:
    sys.exit(0)
elif blocked:
    total = len(blocked)
    print(f'All {total} open epics are blocked.', file=sys.stderr)
    sys.exit(2)
else:
    sys.exit(1)
"
