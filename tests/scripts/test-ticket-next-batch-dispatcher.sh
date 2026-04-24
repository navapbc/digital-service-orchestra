#!/usr/bin/env bash
# tests/scripts/test-ticket-next-batch-dispatcher.sh
# RED integration tests for 'ticket next-batch' subcommand routing through the dispatcher.
#
# Tests verify that the dispatcher correctly routes 'ticket next-batch' to
# sprint-next-batch.sh and that output matches the expected text/JSON format.
#
# Uses TICKETS_TRACKER_DIR injection — sprint-next-batch.sh respects this env var
# directly, and the ticket CLI it calls (TICKET_CMD defaults to same-dir ticket)
# also respects TICKETS_TRACKER_DIR.
#
# RED STATE: Tests 2-6 currently fail because the dispatcher does not have a
# 'next-batch' case. They will pass (GREEN) after the dispatcher case is added.
#
# RED MARKER:
# tests/scripts/test-ticket-next-batch-dispatcher.sh [test_next_batch_routes_through_dispatcher]
#
# Usage: bash tests/scripts/test-ticket-next-batch-dispatcher.sh
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

echo "=== test-ticket-next-batch-dispatcher.sh ==="

# ── Fixture helpers ───────────────────────────────────────────────────────────

# make_next_batch_fixture — creates a .tickets-tracker/ with:
#   nb-epic          (epic, open)
#     nb-story-1     (story, open, no blockers)
#       nb-task-1    (task, open, child of nb-story-1)
#       nb-task-2    (task, open, child of nb-story-1)
#     nb-story-2     (story, open, depends_on nb-story-1 → blocked)
#       nb-task-3    (task, open, child of nb-story-2)
make_next_batch_fixture() {
    local tracker_dir
    tracker_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tracker_dir")

    python3 - "$tracker_dir" <<'PYEOF'
import json, sys, os
base = sys.argv[1]
ts = 1700000000000000000

def write(tid, ts_offset, event_type, data):
    d = os.path.join(base, tid)
    os.makedirs(d, exist_ok=True)
    idx = len(os.listdir(d)) + 1
    evt = {
        "event_type": event_type,
        "ticket_id": tid,
        "timestamp": ts + ts_offset,
        "uuid": f"test-{tid}-{idx:04d}",
        "env_id": "test",
        "author": "test",
        "data": data,
    }
    with open(os.path.join(d, f"{idx:03d}-{event_type}.json"), "w") as f:
        json.dump(evt, f)

# nb-epic
write("nb-epic", 0, "CREATE", {
    "ticket_id": "nb-epic", "title": "NB Epic", "ticket_type": "epic",
    "status": "open", "priority": 1, "parent_id": None,
    "tags": [], "description": "", "notes": "",
})
# nb-story-1 (open, no blockers)
write("nb-story-1", 1, "CREATE", {
    "ticket_id": "nb-story-1", "title": "NB Story One", "ticket_type": "story",
    "status": "open", "priority": 2, "parent_id": "nb-epic",
    "tags": [], "description": "", "notes": "",
})
# nb-task-1
write("nb-task-1", 2, "CREATE", {
    "ticket_id": "nb-task-1", "title": "NB Task One", "ticket_type": "task",
    "status": "open", "priority": 2, "parent_id": "nb-story-1",
    "tags": [], "description": "", "notes": "",
})
# nb-task-2
write("nb-task-2", 3, "CREATE", {
    "ticket_id": "nb-task-2", "title": "NB Task Two", "ticket_type": "task",
    "status": "open", "priority": 2, "parent_id": "nb-story-1",
    "tags": [], "description": "", "notes": "",
})
# nb-story-2 (open, depends_on nb-story-1 → blocked)
write("nb-story-2", 4, "CREATE", {
    "ticket_id": "nb-story-2", "title": "NB Story Two Blocked", "ticket_type": "story",
    "status": "open", "priority": 3, "parent_id": "nb-epic",
    "tags": [], "description": "", "notes": "",
})
write("nb-story-2", 5, "LINK", {
    "relation": "depends_on", "target_id": "nb-story-1",
})
# nb-task-3 (child of blocked nb-story-2)
write("nb-task-3", 6, "CREATE", {
    "ticket_id": "nb-task-3", "title": "NB Task Three Blocked", "ticket_type": "task",
    "status": "open", "priority": 3, "parent_id": "nb-story-2",
    "tags": [], "description": "", "notes": "",
})
PYEOF

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

# ── Tests 2-6: Routing and output contract (RED zone) ────────────────────────
test_next_batch_routes_through_dispatcher() {
    local _tracker _output _exit

    # Test 2: 'ticket next-batch nb-epic' is recognized — not "unknown subcommand"
    echo "Test 2: 'ticket next-batch nb-epic' recognized by dispatcher (not unknown subcommand)"
    _tracker=$(make_next_batch_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" next-batch nb-epic 2>&1) || _exit=$?

    if [[ "${_output,,}" =~ unknown.*subcommand|unrecognized.*subcommand ]]; then
        echo "  FAIL: dispatcher does not recognize 'next-batch' subcommand (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    elif [[ $_exit -ge 5 ]]; then
        echo "  FAIL: dispatcher returned unexpected exit $_exit (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    else
        echo "  PASS: 'next-batch' recognized by dispatcher (exit $_exit)"
        (( PASS++ ))
    fi

    # Test 3: Output contains EPIC: line with the epic ID
    echo "Test 3: Output contains EPIC: line with epic ID"
    _tracker=$(make_next_batch_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" next-batch nb-epic 2>&1) || _exit=$?

    if [[ "$_output" =~ EPIC:.*nb-epic ]]; then
        echo "  PASS: output contains 'EPIC: ... nb-epic'"
        (( PASS++ ))
    else
        echo "  FAIL: output missing EPIC: line with nb-epic (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 4: Output contains BATCH_SIZE: line
    echo "Test 4: Output contains BATCH_SIZE: line"
    _tracker=$(make_next_batch_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" next-batch nb-epic 2>&1) || _exit=$?

    if [[ "$_output" =~ BATCH_SIZE: ]]; then
        echo "  PASS: output contains 'BATCH_SIZE:' line"
        (( PASS++ ))
    else
        echo "  FAIL: output missing BATCH_SIZE: line (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 5: nb-task-3 (child of blocked nb-story-2) produces SKIPPED_BLOCKED_STORY
    echo "Test 5: nb-task-3 (child of blocked story) produces SKIPPED_BLOCKED_STORY"
    _tracker=$(make_next_batch_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" next-batch nb-epic 2>&1) || _exit=$?

    if [[ "$_output" =~ SKIPPED_BLOCKED_STORY.*nb-task-3 ]]; then
        echo "  PASS: nb-task-3 correctly deferred as SKIPPED_BLOCKED_STORY"
        (( PASS++ ))
    else
        echo "  FAIL: nb-task-3 not deferred as SKIPPED_BLOCKED_STORY (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi

    # Test 6: --json flag produces valid JSON with expected keys
    # Note: sprint-next-batch.sh prints a conflict matrix to stderr; capture stdout only.
    echo "Test 6: --json flag produces valid JSON with expected keys"
    _tracker=$(make_next_batch_fixture)
    _exit=0
    _output=$(TICKETS_TRACKER_DIR="$_tracker" "$DISPATCHER" next-batch nb-epic --json 2>/dev/null) || _exit=$?

    if echo "$_output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
required = ['available_pool', 'opus_cap', 'skipped_overlap', 'skipped_blocked_story']
missing = [k for k in required if k not in d]
if missing:
    print('Missing keys: ' + ', '.join(missing), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: --json output is valid JSON with required keys"
        (( PASS++ ))
    else
        echo "  FAIL: --json output is not valid JSON or missing required keys (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi
}

test_next_batch_no_epic_exits_nonzero() {
    local _exit _output

    # Test 7: No args exits non-zero (usage error)
    echo "Test 7: No args exits non-zero"
    _exit=0
    _output=$("$DISPATCHER" next-batch 2>&1) || _exit=$?

    if [[ $_exit -ne 0 ]]; then
        echo "  PASS: 'ticket next-batch' with no args exits non-zero (exit $_exit)"
        (( PASS++ ))
    else
        echo "  FAIL: 'ticket next-batch' with no args exited 0 (RED — expected before GREEN)" >&2
        echo "  Output: $_output" >&2
        (( FAIL++ ))
    fi
}

# Run the RED zone tests
test_next_batch_routes_through_dispatcher
test_next_batch_no_epic_exits_nonzero

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
