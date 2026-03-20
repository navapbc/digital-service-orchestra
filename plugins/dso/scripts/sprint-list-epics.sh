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
TICKETS_DIR="${TICKETS_DIR:-$REPO_ROOT/.tickets}"
INDEX_FILE="$TICKETS_DIR/.index.json"
TK="${TK:-$SCRIPT_DIR/tk}"

# ---------------------------------------------------------------------------
# Staleness guard: compare .md file count vs index entry count.
# If mismatched, rebuild the index before querying.
# ---------------------------------------------------------------------------
_rebuild_index() {
    if [ -x "$TK" ] || command -v "$TK" >/dev/null 2>&1; then
        TICKETS_DIR="$TICKETS_DIR" "$TK" index-rebuild >/dev/null 2>&1 || true
    else
        # Inline rebuild using the same logic as _tk_build_full_index in tk
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

    entry = {'title': title, 'status': status, 'type': type_}
    if priority is not None:
        entry['priority'] = priority
    if deps:
        entry['deps'] = deps
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
    # Count .md files
    md_count=$(python3 -c "
import os
d = '$TICKETS_DIR'
try:
    print(sum(1 for f in os.listdir(d) if f.endswith('.md')))
except OSError:
    print(0)
" 2>/dev/null || echo 0)
    # Count index entries
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

# Run staleness check if index file exists (or even if not — rebuild will create it)
_check_staleness

# ---------------------------------------------------------------------------
# Compute child counts: single grep pass over .tickets/*.md for parent: lines.
# ---------------------------------------------------------------------------
child_counts_json=$(python3 -c "
import os, re, collections

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
    # Only scan frontmatter (between first two --- delimiters)
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

import json
print(json.dumps(dict(counts)))
" 2>/dev/null || echo '{}')

# ---------------------------------------------------------------------------
# Single Python pass: read index once, classify epics, emit output.
# ---------------------------------------------------------------------------
SPRINT_SHOW_ALL="$show_all" SPRINT_TICKETS_DIR="$TICKETS_DIR" SPRINT_CHILD_COUNTS="$child_counts_json" python3 -c "
import json, os, sys

show_all = os.environ.get('SPRINT_SHOW_ALL') == 'true'
tickets_dir = os.environ.get('SPRINT_TICKETS_DIR', '.tickets')
index_file = os.path.join(tickets_dir, '.index.json')

try:
    with open(index_file) as f:
        index = json.load(f)
except Exception:
    index = {}

# Load child counts computed by grep pass
try:
    child_counts = json.loads(os.environ.get('SPRINT_CHILD_COUNTS', '{}'))
except Exception:
    child_counts = {}

# Build lookup for dep status resolution
dep_status = {tid: entry.get('status', 'open') for tid, entry in index.items()}

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
    # An epic is blocked if it has at least one dep whose status is not 'closed'
    is_blocked = any(dep_status.get(dep, 'open') != 'closed' for dep in deps)

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
