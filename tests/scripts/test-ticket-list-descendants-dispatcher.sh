#!/usr/bin/env bash
# tests/scripts/test-ticket-list-descendants-dispatcher.sh
# RED integration tests for 'ticket list-descendants' subcommand routing through the dispatcher.
#
# Tests verify that the dispatcher correctly routes 'ticket list-descendants' to
# ticket-list-descendants.py/sh and that output matches the expected JSON schema.
#
# RED STATE: Tests 2-7 currently fail because the dispatcher does not have a
# 'list-descendants' case. They will pass (GREEN) after the dispatcher case and
# ticket-list-descendants implementation are added.
#
# RED MARKER:
# tests/scripts/test-ticket-list-descendants-dispatcher.sh [test_list_descendants_routes_through_dispatcher]
#
# Usage: bash tests/scripts/test-ticket-list-descendants-dispatcher.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test assertions return non-zero by design;
# -e would abort the script on the first failing test instead of collecting all results.
# REVIEW-DEFENSE: PASS/FAIL counters initialized by run_test.sh `: "${PASS:=0}"` (line 14).
# All test files in this suite use the same sourced-library initialization pattern.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER="$PLUGIN_ROOT/plugins/dso/scripts/ticket"

source "$SCRIPT_DIR/../lib/run_test.sh"

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-ticket-list-descendants-dispatcher.sh ==="

# ── Fixture helpers ───────────────────────────────────────────────────────────

# make_hierarchy_fixture — creates a .tickets-tracker/ event store with a 5-ticket
# hierarchy for BFS descendant walk testing:
#
#   epic-root        (ticket_type: epic, no parent)
#     story-a        (ticket_type: story, parent: epic-root)
#       task-1       (ticket_type: task, parent: story-a)
#       task-2       (ticket_type: task, parent: story-a)
#     story-b        (ticket_type: story, parent: epic-root)
#       bug-1        (ticket_type: bug, parent: story-b)
make_hierarchy_fixture() {
    local tracker_dir
    tracker_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tracker_dir")

    # epic-root — no parent
    mkdir -p "$tracker_dir/epic-root"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'epic-root',
    'timestamp': 1000,
    'author': 'test',
    'data': {
        'ticket_type': 'epic',
        'title': 'Root Epic',
        'parent_id': None
    }
}
json.dump(event, open('$tracker_dir/epic-root/001-CREATE.json', 'w'))
"

    # story-a — child of epic-root
    mkdir -p "$tracker_dir/story-a"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'story-a',
    'timestamp': 1001,
    'author': 'test',
    'data': {
        'ticket_type': 'story',
        'title': 'Story A',
        'parent_id': 'epic-root'
    }
}
json.dump(event, open('$tracker_dir/story-a/001-CREATE.json', 'w'))
"

    # task-1 — child of story-a
    mkdir -p "$tracker_dir/task-1"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'task-1',
    'timestamp': 1002,
    'author': 'test',
    'data': {
        'ticket_type': 'task',
        'title': 'Task 1',
        'parent_id': 'story-a'
    }
}
json.dump(event, open('$tracker_dir/task-1/001-CREATE.json', 'w'))
"

    # task-2 — child of story-a
    mkdir -p "$tracker_dir/task-2"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'task-2',
    'timestamp': 1003,
    'author': 'test',
    'data': {
        'ticket_type': 'task',
        'title': 'Task 2',
        'parent_id': 'story-a'
    }
}
json.dump(event, open('$tracker_dir/task-2/001-CREATE.json', 'w'))
"

    # story-b — child of epic-root
    mkdir -p "$tracker_dir/story-b"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'story-b',
    'timestamp': 1004,
    'author': 'test',
    'data': {
        'ticket_type': 'story',
        'title': 'Story B',
        'parent_id': 'epic-root'
    }
}
json.dump(event, open('$tracker_dir/story-b/001-CREATE.json', 'w'))
"

    # bug-1 — child of story-b
    mkdir -p "$tracker_dir/bug-1"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'bug-1',
    'timestamp': 1005,
    'author': 'test',
    'data': {
        'ticket_type': 'bug',
        'title': 'Bug 1',
        'parent_id': 'story-b'
    }
}
json.dump(event, open('$tracker_dir/bug-1/001-CREATE.json', 'w'))
"

    echo "$tracker_dir"
}

# make_single_ticket_fixture — creates a .tickets-tracker/ with a single ticket
# that has no children. Used to verify graceful empty-result handling.
make_single_ticket_fixture() {
    local tracker_dir
    tracker_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tracker_dir")

    mkdir -p "$tracker_dir/solo-epic"
    python3 -c "
import json
event = {
    'event_type': 'CREATE',
    'ticket_id': 'solo-epic',
    'timestamp': 2000,
    'author': 'test',
    'data': {
        'ticket_type': 'epic',
        'title': 'Solo Epic',
        'parent_id': None
    }
}
json.dump(event, open('$tracker_dir/solo-epic/001-CREATE.json', 'w'))
"

    echo "$tracker_dir"
}

# ── Test 1: Dispatcher exists and is executable ───────────────────────────────
echo "Test 1: Dispatcher exists and is executable"
if [[ -x "$DISPATCHER" ]]; then
    echo "  PASS: dispatcher is executable"
    (( PASS++ ))
else
    echo "  FAIL: $DISPATCHER is not executable or does not exist" >&2
    (( FAIL++ ))
fi

# ── Tests 2-7: Routing and output contract (RED zone) ────────────────────────
test_list_descendants_routes_through_dispatcher() {
    local _tracker _output _exit

    # Test 2: 'ticket list-descendants epic-root' is recognized by the dispatcher
    # (NOT an "unknown subcommand" error) and exits with code < 5
    echo "Test 2: 'ticket list-descendants epic-root' recognized (not unknown subcommand, exit < 5)"
    _tracker=$(make_hierarchy_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" list-descendants epic-root 2>&1) || _exit=$?

    if [[ "${_output,,}" =~ unknown.*subcommand|unrecognized.*subcommand ]]; then
        echo "  FAIL: dispatcher does not recognize 'list-descendants' subcommand (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    elif [[ $_exit -ge 5 ]]; then
        echo "  FAIL: dispatcher returned exit $_exit (>= 5) for valid list-descendants call (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    else
        echo "  PASS: 'list-descendants' recognized by dispatcher (exit $_exit)"
        (( PASS++ ))
    fi

    # Test 3: Output is valid JSON with required top-level keys
    echo "Test 3: Output is valid JSON with keys: epics, stories, tasks, bugs, parents_with_children"
    _tracker=$(make_hierarchy_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" list-descendants epic-root 2>&1) || _exit=$?

    if echo "$_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = ['epics', 'stories', 'tasks', 'bugs', 'parents_with_children']
missing = [k for k in required if k not in d]
if missing:
    print('Missing keys: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: output is valid JSON with all required keys"
        (( PASS++ ))
    else
        echo "  FAIL: output is not valid JSON or missing required keys (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 4: Descendant arrays contain the correct ticket IDs
    # stories: story-a, story-b; tasks: task-1, task-2; bugs: bug-1
    echo "Test 4: Descendant arrays contain correct ticket IDs (stories, tasks, bugs)"
    _tracker=$(make_hierarchy_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" list-descendants epic-root 2>&1) || _exit=$?

    if echo "$_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
errors = []
for tid in ['story-a', 'story-b']:
    if tid not in d.get('stories', []):
        errors.append(tid + ' not in stories')
for tid in ['task-1', 'task-2']:
    if tid not in d.get('tasks', []):
        errors.append(tid + ' not in tasks')
if 'bug-1' not in d.get('bugs', []):
    errors.append('bug-1 not in bugs')
if errors:
    print('Errors: ' + '; '.join(errors), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: stories, tasks, and bugs arrays contain expected descendant IDs"
        (( PASS++ ))
    else
        echo "  FAIL: descendant arrays missing expected IDs (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 5: parents_with_children includes story-a (which has task-1 and task-2)
    echo "Test 5: parents_with_children includes story-a (has child tasks)"
    _tracker=$(make_hierarchy_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" list-descendants epic-root 2>&1) || _exit=$?

    if echo "$_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pwc = d.get('parents_with_children', [])
if 'story-a' not in pwc:
    print('story-a not in parents_with_children: ' + str(pwc), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: parents_with_children includes story-a"
        (( PASS++ ))
    else
        echo "  FAIL: parents_with_children does not include story-a (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 6: No args (missing root ID) exits non-zero
    echo "Test 6: No args exits non-zero"
    _exit=0
    _output=$("$DISPATCHER" list-descendants 2>&1) || _exit=$?

    if [[ $_exit -ne 0 ]]; then
        echo "  PASS: list-descendants with no args exits non-zero (exit $_exit)"
        (( PASS++ ))
    else
        echo "  FAIL: list-descendants with no args exited 0 (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 7: Unknown root ID on a fixture that has no matching ticket produces
    # valid JSON with all-empty arrays (graceful empty result, exit 0)
    echo "Test 7: Unknown root ID returns valid JSON with empty arrays (graceful, exit 0)"
    _tracker=$(make_single_ticket_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" list-descendants unknown-id 2>&1) || _exit=$?

    if echo "$_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = ['epics', 'stories', 'tasks', 'bugs', 'parents_with_children']
errors = []
for k in required:
    if k not in d:
        errors.append('missing key: ' + k)
    elif d[k] != []:
        errors.append(k + ' is not empty: ' + str(d[k]))
if errors:
    print('; '.join(errors), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null && [[ $_exit -eq 0 ]]; then
        echo "  PASS: unknown root ID returns empty JSON arrays with exit 0"
        (( PASS++ ))
    else
        echo "  FAIL: unknown root ID did not return empty JSON arrays with exit 0 (RED — expected before GREEN)" >&2
        echo "  Exit: $_exit  Output: $_output" >&2
        (( FAIL++ ))
    fi
}

# Run the RED zone tests
test_list_descendants_routes_through_dispatcher

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
