#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-sprint-list-epics.sh
# Tests for scripts/sprint-list-epics.sh (index-based rewrite)
#
# Usage: bash lockpick-workflow/tests/scripts/test-sprint-list-epics.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/sprint-list-epics.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-sprint-list-epics.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

make_ticket() {
    local dir="$1" id="$2" type="$3" status="$4" priority="$5" deps="$6" title="$7"
    cat > "$dir/$id.md" << EOF
---
id: $id
type: $type
status: $status
priority: $priority
deps: $deps
---
# $title
EOF
}

make_index() {
    local dir="$1"
    # Build index from all .md files in the dir using the same logic as _tk_build_full_index
    python3 -c "
import json, os, re

tickets_dir = '$dir'
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
        deps = [s.strip().strip('\"').strip(\"'\") for s in inner.split(',') if s.strip()]

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

print(json.dumps(idx, indent=2))
" > "$dir/.index.json"
}

# ── Test 1: Script is executable ─────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 3: No tk ready / tk blocked / tk show calls in the script ────────────
echo "Test 3: No tk ready / tk blocked / tk show calls"
if { grep -q 'tk ready\|tk blocked\|tk show' "$SCRIPT"; test $? -ne 0; }; then
    echo "  PASS: no tk ready/blocked/show calls"
    (( PASS++ ))
else
    echo "  FAIL: found tk ready/blocked/show call in script" >&2
    (( FAIL++ ))
fi

# ── Setup: create fixture tickets dir for remaining tests ─────────────────────
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT

# Create tickets:
#   epic-a: open, priority 3, no deps           → unblocked
#   epic-b: open, priority 1, no deps           → unblocked (higher priority than a)
#   epic-c: in_progress, priority 2, no deps    → in-progress
#   epic-d: open, priority 2, dep on task-x     → blocked (task-x not closed)
#   epic-e: open, priority 2, dep on task-y     → unblocked (task-y is closed)
#   task-x: open, priority 2                    → open (blocker)
#   task-y: closed, priority 2                  → closed (not a blocker)

make_ticket "$TDIR" "epic-a" "epic" "open"       "3" "[]"         "Epic A"
make_ticket "$TDIR" "epic-b" "epic" "open"       "1" "[]"         "Epic B"
make_ticket "$TDIR" "epic-c" "epic" "in_progress" "2" "[]"        "Epic C"
make_ticket "$TDIR" "epic-d" "epic" "open"       "2" "[task-x]"   "Epic D Blocked"
make_ticket "$TDIR" "epic-e" "epic" "open"       "2" "[task-y]"   "Epic E UnblockedDep"
make_ticket "$TDIR" "task-x" "task" "open"       "2" "[]"         "Task X open blocker"
make_ticket "$TDIR" "task-y" "task" "closed"     "2" "[]"         "Task Y closed"
make_index "$TDIR"

# ── Test 4: Exit code 0 when unblocked epics exist ───────────────────────────
echo "Test 4: Exit code 0 when unblocked epics exist"
exit4=0
TICKETS_DIR="$TDIR" bash "$SCRIPT" >/dev/null 2>&1 || exit4=$?
if [ "$exit4" -eq 0 ]; then
    echo "  PASS: exit code 0"
    (( PASS++ ))
else
    echo "  FAIL: expected 0, got $exit4" >&2
    (( FAIL++ ))
fi

# ── Test 5: In-progress epic shown with P* marker ────────────────────────────
echo "Test 5: In-progress epic shown with P* marker"
out5=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null)
if echo "$out5" | grep -q "epic-c.*P\*"; then
    echo "  PASS: in-progress epic shown with P*"
    (( PASS++ ))
else
    echo "  FAIL: in-progress epic not shown with P*" >&2
    echo "  Output: $out5" >&2
    (( FAIL++ ))
fi

# ── Test 6: In-progress epic shown BEFORE unblocked open epics ──────────────
echo "Test 6: In-progress epic listed before open unblocked epics"
first_id=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | head -1 | awk '{print $1}')
if [ "$first_id" = "epic-c" ]; then
    echo "  PASS: in-progress epic (epic-c) is first"
    (( PASS++ ))
else
    echo "  FAIL: first line is '$first_id', expected 'epic-c'" >&2
    (( FAIL++ ))
fi

# ── Test 7: Unblocked epics sorted by priority (lower number = higher priority) ─
echo "Test 7: Unblocked open epics sorted by priority"
# epic-b priority 1, epic-e priority 2, epic-a priority 3
# (epic-c is in_progress, epic-d is blocked)
ids_in_order=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep -v "^BLOCKED" | awk '{print $1}' | tr '\n' ' ' | xargs)
# Expected: epic-c (in_progress first), then epic-b (P1), epic-e (P2), epic-a (P3)
if echo "$ids_in_order" | grep -qE "^epic-c[[:space:]]+epic-b[[:space:]]+epic-e[[:space:]]+epic-a$"; then
    echo "  PASS: epics sorted correctly (in-progress first, then by priority)"
    (( PASS++ ))
else
    echo "  FAIL: order was '$ids_in_order', expected 'epic-c epic-b epic-e epic-a'" >&2
    (( FAIL++ ))
fi

# ── Test 8: Blocked epic NOT shown without --all ─────────────────────────────
echo "Test 8: Blocked epic not shown without --all"
out8=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null)
if echo "$out8" | grep -q "BLOCKED"; then
    echo "  FAIL: BLOCKED prefix appeared without --all" >&2
    (( FAIL++ ))
else
    echo "  PASS: no BLOCKED entries without --all"
    (( PASS++ ))
fi

# ── Test 9: Blocked epic shown with BLOCKED prefix when --all ────────────────
echo "Test 9: Blocked epic shown with BLOCKED prefix when --all"
out9=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" --all 2>/dev/null)
if echo "$out9" | grep -qE "^BLOCKED[[:space:]]+epic-d"; then
    echo "  PASS: blocked epic shown with BLOCKED prefix"
    (( PASS++ ))
else
    echo "  FAIL: blocked epic 'epic-d' not shown with BLOCKED prefix" >&2
    echo "  Output: $out9" >&2
    (( FAIL++ ))
fi

# ── Test 10: Epic with closed dep is NOT blocked ──────────────────────────────
echo "Test 10: Epic with closed dep is not blocked"
out10=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" --all 2>/dev/null)
# epic-e has dep on task-y which is closed, so epic-e should appear unblocked (no BLOCKED prefix)
if echo "$out10" | grep -qE "^BLOCKED.*epic-e"; then
    echo "  FAIL: epic-e (dep closed) incorrectly shown as blocked" >&2
    echo "  Output: $out10" >&2
    (( FAIL++ ))
else
    if echo "$out10" | grep -q "epic-e"; then
        echo "  PASS: epic-e with closed dep shown as unblocked"
        (( PASS++ ))
    else
        echo "  FAIL: epic-e missing from output entirely" >&2
        echo "  Output: $out10" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 11: Exit code 1 when no open epics ───────────────────────────────────
echo "Test 11: Exit code 1 when no open epics"
TDIR_EMPTY=$(mktemp -d)
trap 'rm -rf "$TDIR_EMPTY"' EXIT
# Only closed epic
make_ticket "$TDIR_EMPTY" "epic-z" "epic" "closed" "2" "[]" "Closed Epic"
make_index "$TDIR_EMPTY"
exit11=0
TICKETS_DIR="$TDIR_EMPTY" bash "$SCRIPT" >/dev/null 2>&1 || exit11=$?
if [ "$exit11" -eq 1 ]; then
    echo "  PASS: exit 1 when no open epics"
    (( PASS++ ))
else
    echo "  FAIL: expected 1, got $exit11" >&2
    (( FAIL++ ))
fi

# ── Test 12: Exit code 2 when all open epics are blocked ─────────────────────
echo "Test 12: Exit code 2 when all open epics are blocked"
TDIR_ALLBLOCKED=$(mktemp -d)
trap 'rm -rf "$TDIR_ALLBLOCKED"' EXIT
make_ticket "$TDIR_ALLBLOCKED" "epic-q" "epic" "open"   "2" "[task-w]" "Blocked Epic Q"
make_ticket "$TDIR_ALLBLOCKED" "task-w" "task" "open"   "2" "[]"       "Task W"
make_index "$TDIR_ALLBLOCKED"
exit12=0
TICKETS_DIR="$TDIR_ALLBLOCKED" bash "$SCRIPT" >/dev/null 2>&1 || exit12=$?
if [ "$exit12" -eq 2 ]; then
    echo "  PASS: exit 2 when all open epics blocked"
    (( PASS++ ))
else
    echo "  FAIL: expected 2, got $exit12" >&2
    (( FAIL++ ))
fi

# ── Test 13: Staleness guard triggers rebuild when index count != .md count ───
echo "Test 13: Staleness guard triggers index rebuild on count mismatch"
TDIR_STALE=$(mktemp -d)
trap 'rm -rf "$TDIR_STALE"' EXIT
# Create ticket file but write an EMPTY index (count mismatch: 1 file, 0 entries)
make_ticket "$TDIR_STALE" "epic-stale" "epic" "open" "2" "[]" "Stale Epic"
echo "{}" > "$TDIR_STALE/.index.json"
# Script should detect mismatch and rebuild, then find the epic
out13=""
exit13=0
out13=$(TICKETS_DIR="$TDIR_STALE" bash "$SCRIPT" 2>/dev/null) || exit13=$?
if [ "$exit13" -eq 0 ] && echo "$out13" | grep -q "epic-stale"; then
    echo "  PASS: staleness guard triggered rebuild and found epic"
    (( PASS++ ))
else
    echo "  FAIL: staleness guard did not rebuild (exit=$exit13, output='$out13')" >&2
    (( FAIL++ ))
fi

# ── Test 14: Tab-separated output format (id TAB priority TAB title) ─────────
echo "Test 14: Output is tab-separated (id TAB priority TAB title)"
first_unblocked=$(TICKETS_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep "^epic-b")
field_count=$(echo "$first_unblocked" | awk -F'\t' '{print NF}')
if [ "$field_count" -eq 3 ]; then
    echo "  PASS: output is tab-separated with 3 fields"
    (( PASS++ ))
else
    echo "  FAIL: expected 3 tab-separated fields, got $field_count (line: '$first_unblocked')" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
