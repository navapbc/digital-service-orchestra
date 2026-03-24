#!/usr/bin/env bash
set -euo pipefail
# sprint-list-epics.sh — List unblocked epics for /dso:sprint Phase 1.
#
# Reads .tickets/.index.json in a single Python pass instead of per-file scanning.
# Blocked/ready classification uses the deps field from the extended index schema.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_all=false
[[ "${1:-}" == "--all" ]] && show_all=true

REPO_ROOT=$(git rev-parse --show-toplevel)
# Capture whether TICKETS_DIR was explicitly set by caller before applying defaults
_TICKETS_DIR_EXPLICIT="${TICKETS_DIR+yes}"
TICKETS_DIR="${TICKETS_DIR:-$REPO_ROOT/.tickets}"
INDEX_FILE="$TICKETS_DIR/.index.json"
TK="${TK:-$SCRIPT_DIR/tk}"
REDUCER="$SCRIPT_DIR/ticket-reducer.py"

# ---------------------------------------------------------------------------
# Detect v3 event-sourced ticket system.
# v3 stores events in .tickets-tracker/ (or TICKETS_TRACKER_DIR env override).
# When v3 is detected, build the index from the reducer instead of .md files.
# ---------------------------------------------------------------------------
# Detection logic:
# - TICKETS_TRACKER_DIR explicitly set → v3 (test override for v3)
# - TICKETS_DIR explicitly set without TICKETS_TRACKER_DIR → v2 (test override for v2)
# - Neither explicitly set → auto-detect: use v3 if .tickets-tracker/ exists
USE_V3=false
if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
    TRACKER_DIR="$TICKETS_TRACKER_DIR"
    USE_V3=true
elif [ "$_TICKETS_DIR_EXPLICIT" != "yes" ]; then
    # TICKETS_DIR not explicitly set — auto-detect
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
    if [ -d "$TRACKER_DIR" ]; then
        USE_V3=true
    fi
else
    # TICKETS_DIR explicitly set, TICKETS_TRACKER_DIR not — use v2
    TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
fi

# ---------------------------------------------------------------------------
# Build index from data source (v3 reducer or v2 .md files).
# Both paths produce the same index format in SPRINT_INDEX_JSON env var.
# ---------------------------------------------------------------------------
if [ "$USE_V3" = true ]; then
    # v3 path: compile ticket state from event-sourced tracker via reducer
    export _SPRINT_TRACKER_DIR="$TRACKER_DIR"
    export _SPRINT_REDUCER="$REDUCER"
    index_and_counts=$(python3 -c "
import json, os, sys, importlib.util, collections

tracker_dir = os.environ['_SPRINT_TRACKER_DIR']
reducer_path = os.environ['_SPRINT_REDUCER']

# Load reducer module
spec = importlib.util.spec_from_file_location('ticket_reducer', reducer_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
reduce_ticket = mod.reduce_ticket

idx = {}
child_counts = collections.defaultdict(int)

for entry_name in os.listdir(tracker_dir):
    ticket_dir = os.path.join(tracker_dir, entry_name)
    if not os.path.isdir(ticket_dir) or entry_name.startswith('.'):
        continue
    try:
        state = reduce_ticket(ticket_dir)
    except Exception:
        continue
    if state is None:
        continue

    ticket_id = state.get('ticket_id', entry_name)
    status = state.get('status', 'open')
    ticket_type = state.get('ticket_type', 'task')
    title = state.get('title', '')
    priority = state.get('priority')
    parent_id = state.get('parent_id', '')

    # Build deps: only 'depends_on' entries represent prerequisites of this ticket.
    # 'blocks' entries mean this ticket blocks the target — not that it is blocked.
    deps = [d.get('target_id', '') for d in state.get('deps', [])
            if d.get('relation') == 'depends_on']

    entry = {'title': title, 'status': status, 'type': ticket_type}
    if priority is not None:
        entry['priority'] = priority
    if deps:
        entry['deps'] = deps
    if parent_id:
        entry['parent'] = parent_id
    idx[ticket_id] = entry

    if parent_id:
        child_counts[parent_id] += 1

print(json.dumps({'index': idx, 'child_counts': dict(child_counts)}))
" 2>/dev/null || echo '{"index":{},"child_counts":{}}')

    SPRINT_INDEX_JSON=$(echo "$index_and_counts" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['index']))")
    child_counts_json=$(echo "$index_and_counts" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['child_counts']))")
else
    # v2 path: read .tickets/*.md files and build index

    # Staleness guard: compare .md file count vs index entry count.
    _rebuild_index() {
        if [ -x "$TK" ] || command -v "$TK" >/dev/null 2>&1; then
            TICKETS_DIR="$TICKETS_DIR" "$TK" index-rebuild >/dev/null 2>&1 || true
        else
            python3 -c "
import json, os, re, sys

tickets_dir = os.environ.get('TICKETS_DIR', '.tickets')
idx = {}

try:
    files = [f for f in os.listdir(tickets_dir) if f.endswith('.md')]
except OSError:
    files = []

for fname in files:
    fpath = os.path.join(tickets_dir, fname)
    try:
        content = open(fpath).read()
    except OSError:
        continue

    lines = content.splitlines()
    in_front = False
    front_lines = []
    count = 0
    for line in lines:
        if line.strip() == '---':
            count += 1
            if count == 1:
                in_front = True
                continue
            elif count == 2:
                in_front = False
                break
        if in_front:
            front_lines.append(line)

    def get_field(name):
        for l in front_lines:
            m = re.match(r'^' + re.escape(name) + r':\s*(.*)', l)
            if m:
                return m.group(1).strip()
        return ''

    ticket_id = get_field('id')
    if not ticket_id:
        ticket_id = fname[:-3]

    status = get_field('status') or 'open'
    type_ = get_field('type') or 'task'

    raw_priority = get_field('priority')
    try:
        priority = int(raw_priority) if raw_priority != '' else None
    except (ValueError, TypeError):
        priority = None

    raw_deps = get_field('deps')
    if raw_deps in ('', '[]'):
        deps = []
    else:
        inner = raw_deps.strip().lstrip('[').rstrip(']')
        deps = [s.strip().strip('\"').strip(chr(39)) for s in inner.split(',') if s.strip()]

    title = ''
    for line in lines:
        if line.startswith('# '):
            title = line[2:].strip()
            break

    parent = get_field('parent')

    entry = {'title': title, 'status': status, 'type': type_}
    if priority is not None:
        entry['priority'] = priority
    if deps:
        entry['deps'] = deps
    if parent:
        entry['parent'] = parent
    idx[ticket_id] = entry

# Write atomically
import tempfile
tmp = os.path.join(tickets_dir, '.index.json.tmp')
with open(tmp, 'w') as f:
    json.dump(idx, f, indent=2, sort_keys=True)
os.replace(tmp, os.path.join(tickets_dir, '.index.json'))
" 2>/dev/null || true
        fi
    }

    _check_staleness() {
        local index_count md_count
        md_count=$(python3 -c "
import os
d = '$TICKETS_DIR'
try:
    print(sum(1 for f in os.listdir(d) if f.endswith('.md')))
except OSError:
    print(0)
" 2>/dev/null || echo 0)
        index_count=$(python3 -c "
import json
try:
    with open('$INDEX_FILE') as f:
        data = json.load(f)
    print(len(data))
except Exception:
    print(-1)
" 2>/dev/null || echo -1)
        if [ "$index_count" -ne "$md_count" ]; then
            _rebuild_index
        fi
    }

    _check_staleness

    # Read index file for v2 path
    SPRINT_INDEX_JSON=$(cat "$INDEX_FILE" 2>/dev/null || echo '{}')

    # Compute child counts from .md files
    child_counts_json=$(python3 -c "
import os, re, collections, json

tickets_dir = '$TICKETS_DIR'
counts = collections.defaultdict(int)

try:
    files = [f for f in os.listdir(tickets_dir) if f.endswith('.md')]
except OSError:
    files = []

for fname in files:
    fpath = os.path.join(tickets_dir, fname)
    try:
        content = open(fpath).read()
    except OSError:
        continue
    in_front = False
    front_count = 0
    for line in content.splitlines():
        if line.strip() == '---':
            front_count += 1
            in_front = (front_count == 1)
            if front_count == 2:
                break
            continue
        if in_front:
            m = re.match(r'^parent:\s*(\S+)', line)
            if m:
                parent_id = m.group(1).rstrip('#').strip()
                counts[parent_id] += 1

print(json.dumps(dict(counts)))
" 2>/dev/null || echo '{}')
fi

# ---------------------------------------------------------------------------
# Single Python pass: read index once, classify epics, emit output.
# ---------------------------------------------------------------------------
SPRINT_SHOW_ALL="$show_all" SPRINT_INDEX_JSON="$SPRINT_INDEX_JSON" SPRINT_CHILD_COUNTS="$child_counts_json" python3 -c "
import json, os, sys

show_all = os.environ.get('SPRINT_SHOW_ALL') == 'true'

# Load index from env var (built by v2 or v3 path above)
try:
    index = json.loads(os.environ.get('SPRINT_INDEX_JSON', '{}'))
except Exception:
    index = {}

# Load child counts computed above
try:
    child_counts = json.loads(os.environ.get('SPRINT_CHILD_COUNTS', '{}'))
except Exception:
    child_counts = {}

# Build lookup for dep status and parent resolution
dep_status = {tid: entry.get('status', 'open') for tid, entry in index.items()}
dep_parent = {tid: entry.get('parent', '') for tid, entry in index.items()}

in_progress = []
open_unblocked = []
open_blocked = []

for tid, entry in index.items():
    if entry.get('type') != 'epic':
        continue
    status = entry.get('status', 'open')
    if status in ('closed',):
        continue

    deps = entry.get('deps', [])
    # An epic is blocked only by external deps — exclude deps that are its own children.
    # Preplanning may mistakenly add child story IDs to the epic's deps field (bug w21-3w8y).
    # Children are identified by having parent == this epic's ID.
    external_deps = [dep for dep in deps if dep_parent.get(dep, '') != tid]
    is_blocked = any(dep_status.get(dep, 'open') != 'closed' for dep in external_deps)

    priority = entry.get('priority', 4)
    if priority is None:
        priority = 4
    title = entry.get('title', '')

    children = child_counts.get(tid, 0)

    if status == 'in_progress':
        in_progress.append({'id': tid, 'priority': priority, 'title': title, 'children': children})
    elif is_blocked:
        open_blocked.append({'id': tid, 'priority': priority, 'title': title, 'children': children})
    else:
        open_unblocked.append({'id': tid, 'priority': priority, 'title': title, 'children': children})

# Sort each list by priority
in_progress.sort(key=lambda x: x['priority'])
open_unblocked.sort(key=lambda x: x['priority'])
open_blocked.sort(key=lambda x: x['priority'])

if not in_progress and not open_unblocked and not open_blocked:
    print('No open epics found.', file=sys.stderr)
    sys.exit(1)

# In-progress epics first (P* signals already claimed work)
for e in in_progress:
    print(f'{e[\"id\"]}\tP*\t{e[\"title\"]}\t{e[\"children\"]}')

# Then unblocked open epics
for e in open_unblocked:
    print(f'{e[\"id\"]}\tP{e[\"priority\"]}\t{e[\"title\"]}\t{e[\"children\"]}')

# Blocked epics appended last when --all
if show_all:
    in_progress_ids = {e['id'] for e in in_progress}
    open_unblocked_ids = {e['id'] for e in open_unblocked}
    selectable_ids = in_progress_ids | open_unblocked_ids
    for e in open_blocked:
        if e['id'] not in selectable_ids:
            print(f'BLOCKED\t{e[\"id\"]}\tP{e[\"priority\"]}\t{e[\"title\"]}\t{e[\"children\"]}')

# Exit code logic:
#   0 — at least one unblocked epic (in-progress or ready)
#   2 — open epics exist but all are blocked
#   1 — no open epics at all
if in_progress or open_unblocked:
    sys.exit(0)
elif open_blocked:
    total = len(open_blocked)
    print(f'All {total} open epics are blocked.', file=sys.stderr)
    sys.exit(2)
else:
    sys.exit(1)
"
