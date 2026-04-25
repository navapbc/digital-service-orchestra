#!/usr/bin/env bash
# tests/scripts/test-sprint-list-epics.sh
# Tests for scripts/sprint-list-epics.sh (v3 event-sourced rewrite)
#
# Usage: bash tests/scripts/test-sprint-list-epics.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-list-epics.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-sprint-list-epics.sh ==="

# ── Helpers ──────────────────────────────────────────────────────────────────

# make_v3_ticket: create a v3 event-sourced ticket in a tracker directory.
# Args: tracker_dir id type status priority deps title [parent]
# deps format: space-separated list of target IDs (e.g. "task-x task-y") or "" for none
make_v3_ticket() {
    local tracker_dir="$1" id="$2" type="$3" status="$4" priority="$5"
    local deps_raw="$6" title="$7" parent="${8:-}"

    mkdir -p "$tracker_dir/$id"

    # CREATE event
    local ts=1000000001
    local create_data
    create_data=$(python3 -c "
import json, sys
d = {'ticket_type': sys.argv[1], 'title': sys.argv[2], 'priority': int(sys.argv[3])}
if sys.argv[4]:
    d['parent_id'] = sys.argv[4]
print(json.dumps(d))
" "$type" "$title" "$priority" "$parent")

    cat > "$tracker_dir/$id/${ts}-aaaa-CREATE.json" << EOF
{"timestamp": ${ts}, "uuid": "aaaa-${id}", "event_type": "CREATE", "data": ${create_data}}
EOF

    # STATUS event (if not open)
    if [ "$status" != "open" ]; then
        local ts2=1000000002
        cat > "$tracker_dir/$id/${ts2}-bbbb-STATUS.json" << EOF
{"timestamp": ${ts2}, "uuid": "bbbb-${id}", "event_type": "STATUS", "data": {"status": "${status}"}}
EOF
    fi

    # LINK events for each dependency (reducer uses LINK events, not DEPS)
    if [ -n "$deps_raw" ]; then
        local ts3=1000000003
        local dep_idx=0
        for dep_id in $deps_raw; do
            dep_idx=$(( dep_idx + 1 ))
            local link_ts=$(( ts3 + dep_idx ))
            cat > "$tracker_dir/$id/${link_ts}-link${dep_idx}-${id}-LINK.json" << EOF
{"timestamp": ${link_ts}, "uuid": "link${dep_idx}-${id}", "event_type": "LINK", "data": {"target_id": "${dep_id}", "relation": "depends_on"}}
EOF
        done
    fi
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

# ── Setup: create fixture v3 tracker for remaining tests ─────────────────────
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT

# Create v3 event-sourced tickets in tracker:
#   epic-a: open, priority 3, no deps           → unblocked
#   epic-b: open, priority 1, no deps           → unblocked (higher priority than a)
#   epic-c: in_progress, priority 2, no deps    → in-progress
#   epic-d: open, priority 2, dep on task-x     → blocked (task-x not closed)
#   epic-e: open, priority 2, dep on task-y     → unblocked (task-y is closed)
#   task-x: open, priority 2                    → open (blocker)
#   task-y: closed, priority 2                  → closed (not a blocker)
#   story-c1, story-c2: children of epic-c      → child count 2

make_v3_ticket "$TDIR" "epic-a"   "epic"  "open"        "3" ""        "Epic A"
make_v3_ticket "$TDIR" "epic-b"   "epic"  "open"        "1" ""        "Epic B"
make_v3_ticket "$TDIR" "epic-c"   "epic"  "in_progress" "2" ""        "Epic C"
make_v3_ticket "$TDIR" "epic-d"   "epic"  "open"        "2" "task-x"  "Epic D Blocked"
make_v3_ticket "$TDIR" "epic-e"   "epic"  "open"        "2" "task-y"  "Epic E UnblockedDep"
make_v3_ticket "$TDIR" "task-x"   "task"  "open"        "2" ""        "Task X open blocker"
make_v3_ticket "$TDIR" "task-y"   "task"  "closed"      "2" ""        "Task Y closed"
# Child tickets: epic-c has 2 children (story-c1, story-c2); epic-a has 0 children
make_v3_ticket "$TDIR" "story-c1" "story" "open"        "2" ""        "Story C1" "epic-c"
make_v3_ticket "$TDIR" "story-c2" "story" "open"        "2" ""        "Story C2" "epic-c"

# ── Test 4: Exit code 0 when unblocked epics exist ───────────────────────────
echo "Test 4: Exit code 0 when unblocked epics exist"
exit4=0
TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" >/dev/null 2>&1 || exit4=$?
if [ "$exit4" -eq 0 ]; then
    echo "  PASS: exit code 0"
    (( PASS++ ))
else
    echo "  FAIL: expected 0, got $exit4" >&2
    (( FAIL++ ))
fi

# ── Test 5: In-progress epic shown with P* marker ────────────────────────────
echo "Test 5: In-progress epic shown with P* marker"
out5=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null)
if [[ "$out5" =~ epic-c.*P\* ]]; then
    echo "  PASS: in-progress epic shown with P*"
    (( PASS++ ))
else
    echo "  FAIL: in-progress epic not shown with P*" >&2
    echo "  Output: $out5" >&2
    (( FAIL++ ))
fi

# ── Test 6: In-progress epic shown BEFORE unblocked open epics ──────────────
echo "Test 6: In-progress epic listed before open unblocked epics"
first_id=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | head -1 | awk '{print $1}')
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
ids_in_order=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep -v "^BLOCKED" | awk '{print $1}' | tr '\n' ' ' | xargs)
# Expected: epic-c (in_progress first), then epic-b (P1), epic-e (P2), epic-a (P3)
if [[ "$ids_in_order" =~ ^epic-c[[:space:]]+epic-b[[:space:]]+epic-e[[:space:]]+epic-a$ ]]; then
    echo "  PASS: epics sorted correctly (in-progress first, then by priority)"
    (( PASS++ ))
else
    echo "  FAIL: order was '$ids_in_order', expected 'epic-c epic-b epic-e epic-a'" >&2
    (( FAIL++ ))
fi

# ── Test 8: Blocked epic NOT shown without --all ─────────────────────────────
echo "Test 8: Blocked epic not shown without --all"
out8=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null)
if [[ "$out8" == *BLOCKED* ]]; then
    echo "  FAIL: BLOCKED prefix appeared without --all" >&2
    (( FAIL++ ))
else
    echo "  PASS: no BLOCKED entries without --all"
    (( PASS++ ))
fi

# ── Test 9: Blocked epic shown with BLOCKED prefix when --all ────────────────
echo "Test 9: Blocked epic shown with BLOCKED prefix when --all"
out9=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" --all 2>/dev/null)
if [[ "$out9" =~ (^|$'\n')BLOCKED[[:space:]]+epic-d ]]; then
    echo "  PASS: blocked epic shown with BLOCKED prefix"
    (( PASS++ ))
else
    echo "  FAIL: blocked epic 'epic-d' not shown with BLOCKED prefix" >&2
    echo "  Output: $out9" >&2
    (( FAIL++ ))
fi

# ── Test 10: Epic with closed dep is NOT blocked ──────────────────────────────
echo "Test 10: Epic with closed dep is not blocked"
out10=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" --all 2>/dev/null)
# epic-e has dep on task-y which is closed, so epic-e should appear unblocked (no BLOCKED prefix)
if [[ "$out10" =~ (^|$'\n')BLOCKED.*epic-e ]]; then
    echo "  FAIL: epic-e (dep closed) incorrectly shown as blocked" >&2
    echo "  Output: $out10" >&2
    (( FAIL++ ))
else
    if [[ "$out10" == *epic-e* ]]; then
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
make_v3_ticket "$TDIR_EMPTY" "epic-z" "epic" "closed" "2" "" "Closed Epic"
exit11=0
TICKETS_TRACKER_DIR="$TDIR_EMPTY" bash "$SCRIPT" >/dev/null 2>&1 || exit11=$?
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
make_v3_ticket "$TDIR_ALLBLOCKED" "epic-q"  "epic" "open" "2" "task-w" "Blocked Epic Q"
make_v3_ticket "$TDIR_ALLBLOCKED" "task-w"  "task" "open" "2" ""       "Task W"
exit12=0
TICKETS_TRACKER_DIR="$TDIR_ALLBLOCKED" bash "$SCRIPT" >/dev/null 2>&1 || exit12=$?
if [ "$exit12" -eq 2 ]; then
    echo "  PASS: exit 2 when all open epics blocked"
    (( PASS++ ))
else
    echo "  FAIL: expected 2, got $exit12" >&2
    (( FAIL++ ))
fi

# ── Test 13: Empty tracker directory returns exit 1 (no epics) ───────────────
# v3 has no index file / staleness concept; an empty tracker dir = no tickets.
echo "Test 13: Empty tracker directory returns exit 1"
TDIR_EMPTY2=$(mktemp -d)
trap 'rm -rf "$TDIR_EMPTY2"' EXIT
exit13=0
TICKETS_TRACKER_DIR="$TDIR_EMPTY2" bash "$SCRIPT" >/dev/null 2>&1 || exit13=$?
if [ "$exit13" -eq 1 ]; then
    echo "  PASS: exit 1 for empty tracker"
    (( PASS++ ))
else
    echo "  FAIL: expected 1 for empty tracker, got $exit13" >&2
    (( FAIL++ ))
fi

# ── Test 14: Tab-separated output format (id TAB priority TAB title TAB child_count) ─────────
echo "Test 14: Output is tab-separated (id TAB priority TAB title TAB child_count)"
first_unblocked=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep "^epic-b")
field_count=$(echo "$first_unblocked" | awk -F'\t' '{print NF}')
if [ "$field_count" -eq 4 ]; then
    echo "  PASS: output is tab-separated with 4 fields"
    (( PASS++ ))
else
    echo "  FAIL: expected 4 tab-separated fields, got $field_count (line: '$first_unblocked')" >&2
    (( FAIL++ ))
fi

# ── Test 15: Output has 4th tab-separated field (child count) ───────────────
echo "Test 15: test_child_count_field_present — output has 4th tab-separated field"
test_child_count_field_present() {
    local first_unblocked field_count
    first_unblocked=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep "^epic-b")
    field_count=$(echo "$first_unblocked" | awk -F'\t' '{print NF}')
    [ "$field_count" -eq 4 ]
}
if test_child_count_field_present; then
    echo "  PASS: output has 4 tab-separated fields"
    (( PASS++ ))
else
    echo "  FAILED: expected 4 tab-separated fields for child count (got fewer)" >&2
    (( FAIL++ ))
fi

# ── Test 16: Epic with 2 children shows child count 2 ───────────────────────
echo "Test 16: test_child_count_accuracy — epic-c with 2 children shows count 2"
test_child_count_accuracy() {
    local line child_count
    line=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep "^epic-c")
    child_count=$(echo "$line" | awk -F'\t' '{print $4}')
    [ "$child_count" = "2" ]
}
if test_child_count_accuracy; then
    echo "  PASS: epic-c shows child count 2"
    (( PASS++ ))
else
    echo "  FAILED: expected epic-c to show child count 2 in 4th field" >&2
    (( FAIL++ ))
fi

# ── Test 17: Epic with 0 children shows child count 0 ───────────────────────
echo "Test 17: test_child_count_zero — epic-a with 0 children shows count 0"
test_child_count_zero() {
    local line child_count
    line=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" 2>/dev/null | grep "^epic-a")
    child_count=$(echo "$line" | awk -F'\t' '{print $4}')
    [ "$child_count" = "0" ]
}
if test_child_count_zero; then
    echo "  PASS: epic-a shows child count 0"
    (( PASS++ ))
else
    echo "  FAILED: expected epic-a to show child count 0 in 4th field" >&2
    (( FAIL++ ))
fi

# ── Test 18: Epic whose deps are only its own children is NOT blocked ─────────
echo "Test 18: epic whose deps are only its own children is not blocked"
test_self_children_not_blocked() {
    local TDIR18
    TDIR18=$(mktemp -d)
    trap 'rm -rf "$TDIR18"' RETURN
    # epic-p lists story-p1 and story-p2 as deps (preplanning bug w21-3w8y)
    make_v3_ticket "$TDIR18" "epic-p"   "epic"  "open" "2" "story-p1 story-p2" "Epic P Self-Blocked"
    make_v3_ticket "$TDIR18" "story-p1" "story" "open" "2" ""                  "Story P1" "epic-p"
    make_v3_ticket "$TDIR18" "story-p2" "story" "open" "2" ""                  "Story P2" "epic-p"
    local out18
    out18=$(TICKETS_TRACKER_DIR="$TDIR18" bash "$SCRIPT" --all 2>/dev/null)
    # epic-p should NOT appear with BLOCKED prefix
    ! [[ "$out18" =~ (^|$'\n')BLOCKED.*epic-p ]]
}
if test_self_children_not_blocked; then
    echo "  PASS: epic-p not blocked by its own children"
    (( PASS++ ))
else
    echo "  FAILED: epic-p appeared as BLOCKED even though deps are its own children" >&2
    (( FAIL++ ))
fi

# ── Test 19: v3 event-sourced tickets found without .md files ───────────────
echo "Test 19: test_v3_event_sourced_epics — finds epics from v3 tracker"
test_v3_event_sourced_epics() {
    local TDIR19 TRACKER19
    TDIR19=$(mktemp -d)
    TRACKER19="$TDIR19/tracker"
    mkdir -p "$TRACKER19"

    # Create v3 event-sourced epic: epic-v3a (open, priority 1)
    mkdir -p "$TRACKER19/epic-v3a"
    cat > "$TRACKER19/epic-v3a/1000000001-aaaa-CREATE.json" << 'EVTEOF'
{"timestamp": 1000000001, "uuid": "aaaa", "event_type": "CREATE", "data": {"ticket_type": "epic", "title": "V3 Epic Alpha", "priority": 1}}
EVTEOF

    # Create v3 event-sourced epic: epic-v3b (in_progress, priority 2)
    mkdir -p "$TRACKER19/epic-v3b"
    cat > "$TRACKER19/epic-v3b/1000000002-bbbb-CREATE.json" << 'EVTEOF'
{"timestamp": 1000000002, "uuid": "bbbb", "event_type": "CREATE", "data": {"ticket_type": "epic", "title": "V3 Epic Beta", "priority": 2}}
EVTEOF
    cat > "$TRACKER19/epic-v3b/1000000003-cccc-STATUS.json" << 'EVTEOF'
{"timestamp": 1000000003, "uuid": "cccc", "event_type": "STATUS", "data": {"status": "in_progress"}}
EVTEOF

    # Create v3 event-sourced child story under epic-v3b
    mkdir -p "$TRACKER19/story-v3c"
    cat > "$TRACKER19/story-v3c/1000000004-dddd-CREATE.json" << 'EVTEOF'
{"timestamp": 1000000004, "uuid": "dddd", "event_type": "CREATE", "data": {"ticket_type": "story", "title": "V3 Story Under Beta", "priority": 2, "parent_id": "epic-v3b"}}
EVTEOF

    local out19 exit19=0
    out19=$(TICKETS_TRACKER_DIR="$TRACKER19" bash "$SCRIPT" --all 2>/dev/null) || exit19=$?

    rm -rf "$TDIR19"

    # Exit 0: unblocked epics exist
    [ "$exit19" -eq 0 ] || return 1
    # epic-v3a should appear as unblocked open epic with P1
    [[ "$out19" == *epic-v3a* ]] || return 1
    # epic-v3b should appear with P* prefix (in_progress)
    [[ "$out19" =~ epic-v3b.*P\* ]] || return 1
    # epic-v3b should show child count 1 (story-v3c is its child)
    local v3b_children
    v3b_children=$(echo "$out19" | grep "epic-v3b" | awk -F'\t' '{print $4}')
    [ "$v3b_children" = "1" ] || return 1
}
if test_v3_event_sourced_epics; then
    echo "  PASS: v3 event-sourced epics found"
    (( PASS++ ))
else
    echo "  FAILED: sprint-list-epics.sh cannot find epics from v3 event-sourced tracker" >&2
    (( FAIL++ ))
fi

# ── Test 20: No v2 else branch comment in sprint-list-epics.sh ───────────────
echo "Test 20: test_sprint_list_epics_no_v2_else_branch — no v2 else branch in script"
test_sprint_list_epics_no_v2_else_branch() {
    { grep -q '# v2 path: read .tickets/' "$SCRIPT"; test $? -ne 0; }
}
if test_sprint_list_epics_no_v2_else_branch; then
    echo "  PASS: no v2 else branch comment found"
    (( PASS++ ))
else
    echo "  FAIL: v2 else branch comment '# v2 path: read .tickets/' still present in script" >&2
    (( FAIL++ ))
fi

# ── Test 21: No TICKETS_DIR= variable assignment in sprint-list-epics.sh ──────
echo "Test 21: test_sprint_list_epics_no_TICKETS_DIR_variable — no TICKETS_DIR= in script"
test_sprint_list_epics_no_TICKETS_DIR_variable() {
    { grep -q '^TICKETS_DIR=' "$SCRIPT"; test $? -ne 0; }
}
if test_sprint_list_epics_no_TICKETS_DIR_variable; then
    echo "  PASS: no TICKETS_DIR= assignment found"
    (( PASS++ ))
else
    echo "  FAIL: TICKETS_DIR= assignment still present in script" >&2
    (( FAIL++ ))
fi

# ── Test 22: No INDEX_FILE= variable assignment in sprint-list-epics.sh ───────
echo "Test 22: test_sprint_list_epics_no_INDEX_FILE_variable — no INDEX_FILE= in script"
test_sprint_list_epics_no_INDEX_FILE_variable() {
    { grep -q '^INDEX_FILE=' "$SCRIPT"; test $? -ne 0; }
}
if test_sprint_list_epics_no_INDEX_FILE_variable; then
    echo "  PASS: no INDEX_FILE= assignment found"
    (( PASS++ ))
else
    echo "  FAIL: INDEX_FILE= assignment still present in script" >&2
    (( FAIL++ ))
fi

# ── Test 23: No TK= variable assignment in sprint-list-epics.sh ───────────────
echo "Test 23: test_sprint_list_epics_no_TK_variable — no TK= in script"
test_sprint_list_epics_no_TK_variable() {
    { grep -q '^TK=' "$SCRIPT"; test $? -ne 0; }
}
if test_sprint_list_epics_no_TK_variable; then
    echo "  PASS: no TK= assignment found"
    (( PASS++ ))
else
    echo "  FAIL: TK= assignment still present in script" >&2
    (( FAIL++ ))
fi

# ── Test 24: No _rebuild_index function in sprint-list-epics.sh ───────────────
echo "Test 24: test_sprint_list_epics_no_rebuild_index_function — no _rebuild_index in script"
test_sprint_list_epics_no_rebuild_index_function() {
    { grep -q '_rebuild_index' "$SCRIPT"; test $? -ne 0; }
}
if test_sprint_list_epics_no_rebuild_index_function; then
    echo "  PASS: no _rebuild_index function found"
    (( PASS++ ))
else
    echo "  FAIL: _rebuild_index function still present in script" >&2
    (( FAIL++ ))
fi

# ── Test 25: Retry when tracker dir has entries but reducer returns empty ──────
echo "Test 25: test_retry_on_transient_reducer_failure — retries when tracker not ready"
test_retry_on_transient_reducer_failure() {
    local TDIR25 TRACKER25
    TDIR25=$(mktemp -d)
    TRACKER25="$TDIR25/tracker"
    mkdir -p "$TRACKER25"

    # Create a valid v3 epic
    make_v3_ticket "$TRACKER25" "epic-retry" "epic" "open" "1" "" "Retry Epic"

    # Simulate transient reducer failure by making the epic dir temporarily unreadable.
    # The retry mechanism should detect that the tracker has entries but the index is empty,
    # wait, then retry — at which point the dir is readable and the epic is found.

    # Make the epic dir unreadable (reducer will fail to read events, returns empty index)
    chmod 000 "$TRACKER25/epic-retry"

    # Restore permissions quickly — well before the first retry fires.
    # SPRINT_RETRY_WAIT=0.8 gives an 8x margin over the 0.1s background delay.
    (sleep 0.1 && chmod 755 "$TRACKER25/epic-retry") &
    local restore_pid=$!

    local out25 exit25=0
    out25=$(TICKETS_TRACKER_DIR="$TRACKER25" SPRINT_MAX_RETRIES=3 SPRINT_RETRY_WAIT=0.8 \
        bash "$SCRIPT" 2>/dev/null) || exit25=$?

    wait "$restore_pid" 2>/dev/null || true
    chmod -R 755 "$TRACKER25" 2>/dev/null || true
    rm -rf "$TDIR25"

    # The script should have retried and found the epic
    [ "$exit25" -eq 0 ] || return 1
    [[ "$out25" == *epic-retry* ]] || return 1
}
if test_retry_on_transient_reducer_failure; then
    echo "  PASS: script retries on transient reducer failure"
    (( PASS++ ))
else
    echo "  FAIL: script did not retry — epic-retry not found after transient failure" >&2
    (( FAIL++ ))
fi

# ── Test 26: Retry env vars are respected (SPRINT_MAX_RETRIES=0 means no retry) ─
echo "Test 26: test_no_retry_when_disabled — SPRINT_MAX_RETRIES=0 skips retry"
test_no_retry_when_disabled() {
    local TDIR26
    TDIR26=$(mktemp -d)

    # Empty tracker — no epics at all. With retry disabled, should exit 1 immediately.
    local exit26=0 start_time end_time elapsed
    start_time=$(python3 -c "import time; print(time.time())")
    TICKETS_TRACKER_DIR="$TDIR26" SPRINT_MAX_RETRIES=0 SPRINT_RETRY_WAIT=2 \
        bash "$SCRIPT" >/dev/null 2>&1 || exit26=$?
    end_time=$(python3 -c "import time; print(time.time())")
    elapsed=$(python3 -c "print(float('$end_time') - float('$start_time'))")

    rm -rf "$TDIR26"

    # Should exit 1 (no epics) and not wait 2 seconds for a retry
    [ "$exit26" -eq 1 ] || return 1
    python3 -c "exit(0 if float('$elapsed') < 1.5 else 1)" || return 1
}
if test_no_retry_when_disabled; then
    echo "  PASS: no retry when SPRINT_MAX_RETRIES=0"
    (( PASS++ ))
else
    echo "  FAIL: retry occurred even with SPRINT_MAX_RETRIES=0" >&2
    (( FAIL++ ))
fi

# ── Test 27: Retry works when tracker dir is a symlink (worktree scenario) ─────
echo "Test 27: test_retry_through_symlink — retry detects entries through symlink"
test_retry_through_symlink() {
    local TDIR27 ACTUAL27 SYMLINK27
    TDIR27=$(mktemp -d)
    ACTUAL27="$TDIR27/actual-tracker"
    SYMLINK27="$TDIR27/symlinked-tracker"
    mkdir -p "$ACTUAL27"

    # Create a valid v3 epic in the actual directory
    make_v3_ticket "$ACTUAL27" "epic-symlink" "epic" "open" "1" "" "Symlink Epic"

    # Create a symlink pointing to the actual directory (mimics worktree .tickets-tracker)
    ln -s "$ACTUAL27" "$SYMLINK27"

    # Make the epic dir temporarily unreadable (simulates transient failure).
    # The retry mechanism must detect entries THROUGH the symlink.
    chmod 000 "$ACTUAL27/epic-symlink"

    # Restore permissions before first retry fires
    (sleep 0.1 && chmod 755 "$ACTUAL27/epic-symlink") &
    local restore_pid=$!

    local out27 exit27=0
    out27=$(TICKETS_TRACKER_DIR="$SYMLINK27" SPRINT_MAX_RETRIES=3 SPRINT_RETRY_WAIT=0.8 \
        bash "$SCRIPT" 2>/dev/null) || exit27=$?

    wait "$restore_pid" 2>/dev/null || true
    chmod -R 755 "$ACTUAL27" 2>/dev/null || true
    rm -rf "$TDIR27"

    # The script should have retried (via symlink) and found the epic
    [ "$exit27" -eq 0 ] || return 1
    [[ "$out27" == *epic-symlink* ]] || return 1
}
if test_retry_through_symlink; then
    echo "  PASS: retry works through symlinked tracker dir"
    (( PASS++ ))
else
    echo "  FAIL: retry did not work through symlinked tracker dir" >&2
    (( FAIL++ ))
fi

# ── Test 28: Script initializes tracker when dir doesn't exist (worktree startup) ─
echo "Test 28: test_init_on_missing_tracker — calls ticket-init.sh when tracker missing"
test_init_on_missing_tracker() {
    # Behavioral test: verifies that sprint-list-epics.sh actually invokes ticket-init.sh
    # at runtime when the tracker dir doesn't exist and TICKETS_TRACKER_DIR is not set.
    # This is the root cause of the "No open epics found" bug in fresh worktrees.
    #
    # Strategy: create a temp script dir containing a copy of sprint-list-epics.sh plus
    # a stub ticket-init.sh that records its invocation. Set PROJECT_ROOT to a temp dir
    # that has no .tickets-tracker, so the init guard fires. Verify the stub was called.
    local TDIR28 STUB_CALLED
    TDIR28=$(mktemp -d)
    STUB_CALLED="$TDIR28/init-was-called"

    # Copy the real script into the temp dir
    cp "$SCRIPT" "$TDIR28/sprint-list-epics.sh"
    chmod +x "$TDIR28/sprint-list-epics.sh"
    # Also copy ticket-list-epics.sh — sprint-list-epics.sh is now a thin wrapper that execs it
    cp "$DSO_PLUGIN_DIR/scripts/ticket-list-epics.sh" "$TDIR28/ticket-list-epics.sh"
    chmod +x "$TDIR28/ticket-list-epics.sh"

    # Create a stub ticket-init.sh that records invocation
    cat > "$TDIR28/ticket-init.sh" << 'STUBEOF'
#!/usr/bin/env bash
touch "$STUB_CALLED_FILE"
exit 0
STUBEOF
    chmod +x "$TDIR28/ticket-init.sh"

    # PROJECT_ROOT has no .tickets-tracker; TICKETS_TRACKER_DIR is unset (default path)
    # The script will compute TRACKER_DIR=$PROJECT_ROOT/.tickets-tracker, which doesn't exist,
    # and TICKETS_TRACKER_DIR is empty — so the init guard should fire.
    local fake_root="$TDIR28/fake-repo"
    mkdir -p "$fake_root"

    STUB_CALLED_FILE="$STUB_CALLED" PROJECT_ROOT="$fake_root" \
        bash "$TDIR28/sprint-list-epics.sh" >/dev/null 2>&1 || true

    # Check before cleanup — stub creates the file only if it was called
    local was_called=false
    [ -f "$STUB_CALLED" ] && was_called=true

    rm -rf "$TDIR28"

    [ "$was_called" = "true" ]
}
if test_init_on_missing_tracker; then
    echo "  PASS: script calls ticket-init.sh when tracker dir missing"
    (( PASS++ ))
else
    echo "  FAIL: script did not call ticket-init.sh — fresh worktrees will fail" >&2
    (( FAIL++ ))
fi

# ── Test 29: Tracker init only runs for default path, not TICKETS_TRACKER_DIR ──
echo "Test 29: test_init_skipped_for_override — no init when TICKETS_TRACKER_DIR is set"
test_init_skipped_for_override() {
    # Behavioral test: verifies that ticket-init.sh is NOT called when TICKETS_TRACKER_DIR
    # is explicitly set (test/CI environments where the caller provides the tracker dir).
    # The init guard condition is: [ ! -d "$TRACKER_DIR" ] && [ -z "${TICKETS_TRACKER_DIR:-}" ]
    # When TICKETS_TRACKER_DIR is set, the second clause is false, so init must NOT run.
    local TDIR29 STUB_CALLED
    TDIR29=$(mktemp -d)
    STUB_CALLED="$TDIR29/init-was-called"

    # Copy the real script into the temp dir
    cp "$SCRIPT" "$TDIR29/sprint-list-epics.sh"
    chmod +x "$TDIR29/sprint-list-epics.sh"
    # Also copy ticket-list-epics.sh — sprint-list-epics.sh is now a thin wrapper that execs it
    cp "$DSO_PLUGIN_DIR/scripts/ticket-list-epics.sh" "$TDIR29/ticket-list-epics.sh"
    chmod +x "$TDIR29/ticket-list-epics.sh"

    # Stub ticket-init.sh records if called
    cat > "$TDIR29/ticket-init.sh" << 'STUBEOF'
#!/usr/bin/env bash
touch "$STUB_CALLED_FILE"
exit 0
STUBEOF
    chmod +x "$TDIR29/ticket-init.sh"

    # TICKETS_TRACKER_DIR is explicitly set to a non-existent path —
    # the tracker dir doesn't exist, but init must NOT be called because the override is set.
    local nonexistent_tracker="$TDIR29/no-such-tracker"

    STUB_CALLED_FILE="$STUB_CALLED" TICKETS_TRACKER_DIR="$nonexistent_tracker" \
        bash "$TDIR29/sprint-list-epics.sh" >/dev/null 2>&1 || true

    # Check before cleanup — if init was incorrectly called, the file exists
    local was_called=false
    [ -f "$STUB_CALLED" ] && was_called=true

    rm -rf "$TDIR29"

    # The stub file must NOT have been created (init was skipped)
    [ "$was_called" = "false" ]
}
if test_init_skipped_for_override; then
    echo "  PASS: init is skipped when TICKETS_TRACKER_DIR is set"
    (( PASS++ ))
else
    echo "  FAIL: init was called even though TICKETS_TRACKER_DIR is set" >&2
    (( FAIL++ ))
fi

# ── Test 30: Init failure stderr is surfaced, not swallowed ──────────────────
echo "Test 30: test_init_failure_emits_stderr — diagnostic output reaches stderr when init fails"
test_init_failure_emits_stderr() {
    # Behavioral test: verifies that when ticket-init.sh exits non-zero, its stderr
    # is not silently discarded. The current `2>/dev/null || true` pattern swallows
    # both the exit code and the error message, so this test will FAIL (RED) until
    # the warn-on-failure pattern is implemented.
    local TDIR30
    TDIR30=$(mktemp -d)

    # Copy the real script into the temp dir so SCRIPT_DIR resolves to the stub's location
    cp "$SCRIPT" "$TDIR30/sprint-list-epics.sh"
    chmod +x "$TDIR30/sprint-list-epics.sh"
    # Also copy ticket-list-epics.sh — sprint-list-epics.sh is now a thin wrapper that execs it
    cp "$DSO_PLUGIN_DIR/scripts/ticket-list-epics.sh" "$TDIR30/ticket-list-epics.sh"
    chmod +x "$TDIR30/ticket-list-epics.sh"

    # Stub ticket-init.sh: emits a diagnostic on stderr and exits non-zero
    cat > "$TDIR30/ticket-init.sh" << 'STUBEOF'
#!/usr/bin/env bash
echo "ERROR: tracker mount failed" >&2
exit 1
STUBEOF
    chmod +x "$TDIR30/ticket-init.sh"

    # PROJECT_ROOT has no .tickets-tracker; TICKETS_TRACKER_DIR is unset (default path)
    # so the init guard fires, runs the stub, and the stub fails with a message.
    local fake_root="$TDIR30/fake-repo"
    mkdir -p "$fake_root"

    local captured_stderr
    captured_stderr=$(PROJECT_ROOT="$fake_root" \
        bash "$TDIR30/sprint-list-epics.sh" 2>&1 >/dev/null) || true

    rm -rf "$TDIR30"

    # The stub's error message must appear in stderr — not be silently swallowed
    [[ "$captured_stderr" == *"tracker mount failed"* ]]
}
if test_init_failure_emits_stderr; then
    echo "  PASS: init failure diagnostic is emitted on stderr"
    (( PASS++ ))
else
    echo "  FAIL: init failure stderr was silently swallowed — diagnostic output lost" >&2
    (( FAIL++ ))
fi

# ── Test 31: BLOCKED line includes 6th field with single blocker ID ──────────
echo "Test 31: test_blocked_line_includes_blocker_id — BLOCKED output 6th field contains blocker ID"
test_blocked_line_includes_blocker_id() {
    # epic-d (from shared fixture) is blocked by task-x (open).
    # The BLOCKED output line must include a 6th tab-separated field containing "task-x".
    local out31 blocked_line field6 field_count
    out31=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" --all 2>/dev/null)
    blocked_line=$(echo "$out31" | grep -E "^BLOCKED	epic-d")
    field_count=$(echo "$blocked_line" | awk -F'\t' '{print NF}')
    field6=$(echo "$blocked_line" | awk -F'\t' '{print $6}')
    # Must have at least 6 fields
    [ "$field_count" -ge 6 ] || return 1
    # The 6th field must contain the blocker ID
    [[ "$field6" == *"task-x"* ]] || return 1
}
if test_blocked_line_includes_blocker_id; then
    echo "  PASS: BLOCKED line for epic-d includes blocker ID 'task-x' in 6th field"
    (( PASS++ ))
else
    echo "  FAIL: BLOCKED line for epic-d missing 6th field with blocker ID 'task-x'" >&2
    actual_line=$(TICKETS_TRACKER_DIR="$TDIR" bash "$SCRIPT" --all 2>/dev/null | grep -E "^BLOCKED	epic-d" || true)
    echo "  Actual line: '$actual_line'" >&2
    echo "  Field count: $(echo "$actual_line" | awk -F'\t' '{print NF}')" >&2
    (( FAIL++ ))
fi

# ── Test 32: BLOCKED line includes comma-separated IDs for multiple blockers ──
echo "Test 32: test_blocked_line_includes_multiple_blocker_ids — comma-separated blocker IDs in 6th field"
test_blocked_line_includes_multiple_blocker_ids() {
    local TDIR32
    TDIR32=$(mktemp -d)
    trap 'rm -rf "$TDIR32"' RETURN
    # epic-multi is blocked by two open tasks: task-m1 and task-m2
    make_v3_ticket "$TDIR32" "epic-multi" "epic" "open" "2" "task-m1 task-m2" "Epic Multi Blocked"
    make_v3_ticket "$TDIR32" "task-m1"   "task" "open" "2" ""                 "Task M1 open blocker"
    make_v3_ticket "$TDIR32" "task-m2"   "task" "open" "2" ""                 "Task M2 open blocker"

    local out32 blocked_line field6 field_count
    out32=$(TICKETS_TRACKER_DIR="$TDIR32" bash "$SCRIPT" --all 2>/dev/null)
    blocked_line=$(echo "$out32" | grep -E "^BLOCKED	epic-multi")
    field_count=$(echo "$blocked_line" | awk -F'\t' '{print NF}')
    field6=$(echo "$blocked_line" | awk -F'\t' '{print $6}')
    # Must have at least 6 fields
    [ "$field_count" -ge 6 ] || return 1
    # Both blocker IDs must appear in the 6th field (order not guaranteed)
    [[ "$field6" == *"task-m1"* ]] || return 1
    [[ "$field6" == *"task-m2"* ]] || return 1
}
if test_blocked_line_includes_multiple_blocker_ids; then
    echo "  PASS: BLOCKED line for epic-multi includes both 'task-m1' and 'task-m2' in 6th field"
    (( PASS++ ))
else
    echo "  FAIL: BLOCKED line for epic-multi missing comma-separated blocker IDs in 6th field" >&2
    TDIR32_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR32_DBG" "epic-multi" "epic" "open" "2" "task-m1 task-m2" "Epic Multi Blocked"
    make_v3_ticket "$TDIR32_DBG" "task-m1"    "task" "open" "2" ""                "Task M1 open blocker"
    make_v3_ticket "$TDIR32_DBG" "task-m2"    "task" "open" "2" ""                "Task M2 open blocker"
    actual_line=$(TICKETS_TRACKER_DIR="$TDIR32_DBG" bash "$SCRIPT" --all 2>/dev/null | grep -E "^BLOCKED	epic-multi" || true)
    echo "  Actual line: '$actual_line'" >&2
    echo "  Field count: $(echo "$actual_line" | awk -F'\t' '{print NF}')" >&2
    rm -rf "$TDIR32_DBG"
    (( FAIL++ ))
fi

# ── Test 33: Only open deps appear in 6th field (closed deps excluded) ────────
echo "Test 33: test_blocked_line_excludes_closed_blocker — 6th field contains only open blocker, not closed dep"
test_blocked_line_excludes_closed_blocker() {
    local TDIR33
    TDIR33=$(mktemp -d)
    trap 'rm -rf "$TDIR33"' RETURN
    # epic-mixed depends on task-closed (closed) and task-open (open).
    # Only task-open remains a blocker; task-closed must NOT appear in the 6th field.
    make_v3_ticket "$TDIR33" "epic-mixed"  "epic" "open"   "2" "task-closed task-open" "Epic Mixed Deps"
    make_v3_ticket "$TDIR33" "task-closed" "task" "closed" "2" ""                      "Task Closed (done)"
    make_v3_ticket "$TDIR33" "task-open"   "task" "open"   "2" ""                      "Task Open (blocker)"

    local out33 blocked_line field6 field_count
    out33=$(TICKETS_TRACKER_DIR="$TDIR33" bash "$SCRIPT" --all 2>/dev/null)
    blocked_line=$(echo "$out33" | grep -E "^BLOCKED	epic-mixed")
    field_count=$(echo "$blocked_line" | awk -F'\t' '{print NF}')
    field6=$(echo "$blocked_line" | awk -F'\t' '{print $6}')
    # Must have at least 6 fields
    [ "$field_count" -ge 6 ] || return 1
    # Only open blocker must appear
    [[ "$field6" == *"task-open"* ]] || return 1
    # Closed dep must NOT appear in blocker list
    [[ "$field6" != *"task-closed"* ]] || return 1
}
if test_blocked_line_excludes_closed_blocker; then
    echo "  PASS: BLOCKED line for epic-mixed contains 'task-open' but not 'task-closed' in 6th field"
    (( PASS++ ))
else
    echo "  FAIL: BLOCKED line for epic-mixed has wrong blockers in 6th field (expected only open blocker)" >&2
    TDIR33_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR33_DBG" "epic-mixed"  "epic" "open"   "2" "task-closed task-open" "Epic Mixed Deps"
    make_v3_ticket "$TDIR33_DBG" "task-closed" "task" "closed" "2" ""                      "Task Closed (done)"
    make_v3_ticket "$TDIR33_DBG" "task-open"   "task" "open"   "2" ""                      "Task Open (blocker)"
    actual_line=$(TICKETS_TRACKER_DIR="$TDIR33_DBG" bash "$SCRIPT" --all 2>/dev/null | grep -E "^BLOCKED	epic-mixed" || true)
    echo "  Actual line: '$actual_line'" >&2
    echo "  Field count: $(echo "$actual_line" | awk -F'\t' '{print NF}')" >&2
    rm -rf "$TDIR33_DBG"
    (( FAIL++ ))
fi

# ── Test 34: Unblocked epic that blocks another has BLOCKING marker ──────────
echo "Test 34: test_blocking_epic_has_marker — unblocked epic blocking another epic shows BLOCKING in 5th field"
test_blocking_epic_has_marker() {
    local TDIR34
    TDIR34=$(mktemp -d)
    trap 'rm -rf "$TDIR34"' RETURN
    # epic-blocker: open, unblocked (no deps of its own)
    # epic-blocked: open, depends on epic-blocker (so epic-blocker IS blocking epic-blocked)
    make_v3_ticket "$TDIR34" "epic-blocker" "epic" "open" "1" ""             "Epic Blocker"
    make_v3_ticket "$TDIR34" "epic-blocked" "epic" "open" "2" "epic-blocker" "Epic Blocked"

    local out34 blocker_line field5 field_count
    out34=$(TICKETS_TRACKER_DIR="$TDIR34" bash "$SCRIPT" --all 2>/dev/null)
    blocker_line=$(echo "$out34" | grep -E "^epic-blocker")
    field_count=$(echo "$blocker_line" | awk -F'\t' '{print NF}')
    field5=$(echo "$blocker_line" | awk -F'\t' '{print $5}')
    # Must have 5 fields
    [ "$field_count" -ge 5 ] || return 1
    # The 5th field must be BLOCKING
    [ "$field5" = "BLOCKING" ] || return 1
}
if test_blocking_epic_has_marker; then
    echo "  PASS: epic-blocker line has 5th field 'BLOCKING'"
    (( PASS++ ))
else
    echo "  FAIL: epic-blocker line missing 5th field 'BLOCKING'" >&2
    TDIR34_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR34_DBG" "epic-blocker" "epic" "open" "1" ""             "Epic Blocker"
    make_v3_ticket "$TDIR34_DBG" "epic-blocked" "epic" "open" "2" "epic-blocker" "Epic Blocked"
    actual_line=$(TICKETS_TRACKER_DIR="$TDIR34_DBG" bash "$SCRIPT" --all 2>/dev/null | grep -E "^epic-blocker" || true)
    echo "  Actual line: '$actual_line'" >&2
    echo "  Field count: $(echo "$actual_line" | awk -F'\t' '{print NF}')" >&2
    rm -rf "$TDIR34_DBG"
    (( FAIL++ ))
fi

# ── Test 35: BLOCKING marker is selective — only blocking epics get it ────────
echo "Test 35: test_blocking_marker_is_selective — blocker gets BLOCKING, non-blocker gets exactly 4 fields"
test_blocking_marker_is_selective() {
    local TDIR35
    TDIR35=$(mktemp -d)
    trap 'rm -rf "$TDIR35"' RETURN
    # epic-blocker2: open, unblocked — IS blocking epic-blocked2 (should get BLOCKING marker)
    # epic-blocked2: open, depends on epic-blocker2 — IS blocked (no BLOCKING marker)
    # epic-plain: open, unblocked, no dependents — NOT blocking anyone (no BLOCKING marker)
    make_v3_ticket "$TDIR35" "epic-blocker2" "epic" "open" "1" ""              "Epic Blocker2"
    make_v3_ticket "$TDIR35" "epic-blocked2" "epic" "open" "2" "epic-blocker2" "Epic Blocked2"
    make_v3_ticket "$TDIR35" "epic-plain"    "epic" "open" "3" ""              "Epic Plain"

    local out35 blocker2_line plain_line blocker2_field5 plain_field5
    out35=$(TICKETS_TRACKER_DIR="$TDIR35" bash "$SCRIPT" --all 2>/dev/null)

    # epic-blocker2 IS a blocker — must have BLOCKING in 5th field
    blocker2_line=$(echo "$out35" | grep -E "^epic-blocker2")
    blocker2_field5=$(echo "$blocker2_line" | awk -F'\t' '{print $5}')
    [ "$blocker2_field5" = "BLOCKING" ] || return 1

    # epic-plain is NOT a blocker — must have exactly 4 fields (no 5th field)
    plain_line=$(echo "$out35" | grep -E "^epic-plain")
    plain_field5=$(echo "$plain_line" | awk -F'\t' '{print $5}')
    [ -z "$plain_field5" ] || return 1
}
if test_blocking_marker_is_selective; then
    echo "  PASS: epic-blocker2 has BLOCKING in 5th field; epic-plain has no 5th field"
    (( PASS++ ))
else
    echo "  FAIL: BLOCKING marker selectivity incorrect (blocker missing marker OR non-blocker has it)" >&2
    TDIR35_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR35_DBG" "epic-blocker2" "epic" "open" "1" ""              "Epic Blocker2"
    make_v3_ticket "$TDIR35_DBG" "epic-blocked2" "epic" "open" "2" "epic-blocker2" "Epic Blocked2"
    make_v3_ticket "$TDIR35_DBG" "epic-plain"    "epic" "open" "3" ""              "Epic Plain"
    actual_out=$(TICKETS_TRACKER_DIR="$TDIR35_DBG" bash "$SCRIPT" --all 2>/dev/null || true)
    echo "  Full output:" >&2
    echo "$actual_out" >&2
    rm -rf "$TDIR35_DBG"
    (( FAIL++ ))
fi

# ── Test 36: In-progress epic that blocks another epic has BLOCKING marker ────
echo "Test 36: test_in_progress_blocking_epic_has_marker — in-progress epic blocking another shows BLOCKING in 5th field"
test_in_progress_blocking_epic_has_marker() {
    local TDIR36
    TDIR36=$(mktemp -d)
    trap 'rm -rf "$TDIR36"' RETURN
    # epic-ip: in_progress — is a dependency of epic-waiting
    # epic-waiting: open, depends on epic-ip (so epic-ip IS blocking epic-waiting)
    make_v3_ticket "$TDIR36" "epic-ip"      "epic" "in_progress" "1" ""        "Epic In Progress"
    make_v3_ticket "$TDIR36" "epic-waiting" "epic" "open"        "2" "epic-ip" "Epic Waiting"

    local out36 ip_line field5 field_count
    out36=$(TICKETS_TRACKER_DIR="$TDIR36" bash "$SCRIPT" --all 2>/dev/null)
    ip_line=$(echo "$out36" | grep -E "^epic-ip")
    field_count=$(echo "$ip_line" | awk -F'\t' '{print NF}')
    field5=$(echo "$ip_line" | awk -F'\t' '{print $5}')
    # Must have 5 fields (P* marker + BLOCKING marker)
    [ "$field_count" -ge 5 ] || return 1
    # The 5th field must be BLOCKING
    [ "$field5" = "BLOCKING" ] || return 1
}
if test_in_progress_blocking_epic_has_marker; then
    echo "  PASS: in-progress epic-ip line has 5th field 'BLOCKING'"
    (( PASS++ ))
else
    echo "  FAIL: in-progress epic-ip line missing 5th field 'BLOCKING'" >&2
    TDIR36_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR36_DBG" "epic-ip"      "epic" "in_progress" "1" ""        "Epic In Progress"
    make_v3_ticket "$TDIR36_DBG" "epic-waiting" "epic" "open"        "2" "epic-ip" "Epic Waiting"
    actual_line=$(TICKETS_TRACKER_DIR="$TDIR36_DBG" bash "$SCRIPT" --all 2>/dev/null | grep -E "^epic-ip" || true)
    echo "  Actual line: '$actual_line'" >&2
    echo "  Field count: $(echo "$actual_line" | awk -F'\t' '{print NF}')" >&2
    rm -rf "$TDIR36_DBG"
    (( FAIL++ ))
fi

# ── Test 37: P0 bugs appear above the epic list when they exist ──────────────
echo "Test 37: test_p0_bugs_appear_above_epics — P0 bug section is shown above epic list"
test_p0_bugs_appear_above_epics() {
    local TDIR37
    TDIR37=$(mktemp -d)
    trap 'rm -rf "$TDIR37"' RETURN

    # Create a P0 bug and a regular epic
    make_v3_ticket "$TDIR37" "bug-p0"  "bug"  "open" "0" "" "Critical P0 Bug"
    make_v3_ticket "$TDIR37" "epic-x"  "epic" "open" "2" "" "Epic X"

    local out37
    out37=$(TICKETS_TRACKER_DIR="$TDIR37" bash "$SCRIPT" 2>/dev/null)

    # P0 section header must appear
    [[ "$out37" == *P0\ bugs\ requiring\ attention:* ]] || return 1
    # The P0 bug line must reference the bug ID, title, and "(P0)"
    [[ "$out37" == *bug-p0* ]] || return 1
    [[ "$out37" == *Critical\ P0\ Bug* ]] || return 1
    [[ "$out37" == *\(P0\)* ]] || return 1

    # The P0 section must appear BEFORE the epic list (bug-p0 line before epic-x line)
    local p0_line_num epic_line_num
    p0_line_num=$(echo "$out37" | grep -n "bug-p0" | head -1 | cut -d: -f1)
    epic_line_num=$(echo "$out37" | grep -n "epic-x" | head -1 | cut -d: -f1)
    [ -n "$p0_line_num" ] && [ -n "$epic_line_num" ] || return 1
    [ "$p0_line_num" -lt "$epic_line_num" ] || return 1
}
if test_p0_bugs_appear_above_epics; then
    echo "  PASS: P0 bugs appear above epic list"
    (( PASS++ ))
else
    echo "  FAIL: P0 bugs not shown above epic list" >&2
    TDIR37_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR37_DBG" "bug-p0" "bug"  "open" "0" "" "Critical P0 Bug"
    make_v3_ticket "$TDIR37_DBG" "epic-x" "epic" "open" "2" "" "Epic X"
    actual_out37=$(TICKETS_TRACKER_DIR="$TDIR37_DBG" bash "$SCRIPT" 2>/dev/null || true)
    echo "  Output:" >&2
    echo "$actual_out37" >&2
    rm -rf "$TDIR37_DBG"
    (( FAIL++ ))
fi

# ── Test 38: No P0 section when no P0 bugs exist ──────────────────────────────
echo "Test 38: test_no_p0_section_when_none_exist — P0 section absent when no P0 bugs"
test_no_p0_section_when_none_exist() {
    local TDIR38
    TDIR38=$(mktemp -d)
    trap 'rm -rf "$TDIR38"' RETURN

    # Create a P1 bug (not P0) and a regular epic
    make_v3_ticket "$TDIR38" "bug-p1"  "bug"  "open" "1" "" "Lower Priority Bug"
    make_v3_ticket "$TDIR38" "epic-y"  "epic" "open" "2" "" "Epic Y"

    local out38
    out38=$(TICKETS_TRACKER_DIR="$TDIR38" bash "$SCRIPT" 2>/dev/null)

    # P0 section must NOT appear
    ! [[ "$out38" == *P0\ bugs\ requiring\ attention:* ]]
}
if test_no_p0_section_when_none_exist; then
    echo "  PASS: no P0 section when no P0 bugs exist"
    (( PASS++ ))
else
    echo "  FAIL: P0 section appeared even though no P0 bugs exist" >&2
    TDIR38_DBG=$(mktemp -d)
    make_v3_ticket "$TDIR38_DBG" "bug-p1" "bug"  "open" "1" "" "Lower Priority Bug"
    make_v3_ticket "$TDIR38_DBG" "epic-y" "epic" "open" "2" "" "Epic Y"
    actual_out38=$(TICKETS_TRACKER_DIR="$TDIR38_DBG" bash "$SCRIPT" 2>/dev/null || true)
    echo "  Output:" >&2
    echo "$actual_out38" >&2
    rm -rf "$TDIR38_DBG"
    (( FAIL++ ))
fi

# ── Test 39: --min-children=1 excludes epics with 0 children ─────────────────
echo "Test 39: test_min_children_filters_zero_child_epics — --min-children=1 excludes epics with 0 children"
test_min_children_filters_zero_child_epics() {
    local TDIR39
    TDIR39=$(mktemp -d)
    trap 'rm -rf "$TDIR39"' RETURN
    # epic-has-children: open, has 1 child story
    # epic-no-children: open, 0 children
    make_v3_ticket "$TDIR39" "epic-has-children" "epic"  "open" "2" "" "Epic With Children"
    make_v3_ticket "$TDIR39" "epic-no-children"  "epic"  "open" "2" "" "Epic Without Children"
    make_v3_ticket "$TDIR39" "story-ch1"         "story" "open" "2" "" "Story Ch1" "epic-has-children"

    local out39
    out39=$(TICKETS_TRACKER_DIR="$TDIR39" bash "$SCRIPT" --min-children=1 2>/dev/null)
    # epic-has-children (1 child) must appear
    [[ "$out39" == *epic-has-children* ]] || return 1
    # epic-no-children (0 children) must NOT appear
    ! [[ "$out39" == *epic-no-children* ]] || return 1
}
if test_min_children_filters_zero_child_epics; then
    echo "  PASS: --min-children=1 excludes epics with 0 children"
    (( PASS++ ))
else
    echo "  test_min_children_filters_zero_child_epics: FAIL — --min-children=1 did not filter out 0-child epics" >&2
    (( FAIL++ ))
fi

# ── Test 40: --max-children=0 shows only 0-child epics ───────────────────────
echo "Test 40: test_max_children_zero_shows_only_zero_child — --max-children=0 shows only epics with 0 children"
test_max_children_zero_shows_only_zero_child() {
    local TDIR40
    TDIR40=$(mktemp -d)
    trap 'rm -rf "$TDIR40"' RETURN
    # epic-with-child: open, has 1 child
    # epic-empty: open, no children
    make_v3_ticket "$TDIR40" "epic-with-child" "epic"  "open" "2" "" "Epic With Child"
    make_v3_ticket "$TDIR40" "epic-empty"      "epic"  "open" "2" "" "Epic Empty"
    make_v3_ticket "$TDIR40" "story-mc1"       "story" "open" "2" "" "Story MC1" "epic-with-child"

    local out40
    out40=$(TICKETS_TRACKER_DIR="$TDIR40" bash "$SCRIPT" --max-children=0 2>/dev/null)
    # epic-empty (0 children) must appear
    [[ "$out40" == *epic-empty* ]] || return 1
    # epic-with-child (1 child) must NOT appear
    ! [[ "$out40" == *epic-with-child* ]] || return 1
}
if test_max_children_zero_shows_only_zero_child; then
    echo "  PASS: --max-children=0 shows only epics with 0 children"
    (( PASS++ ))
else
    echo "  test_max_children_zero_shows_only_zero_child: FAIL — --max-children=0 did not restrict output to 0-child epics" >&2
    (( FAIL++ ))
fi

# ── Test 41: --max-children=0 is treated as set (not unset) ──────────────────
echo "Test 41: test_max_children_zero_set_check — 0 is not treated as unset for --max-children"
test_max_children_zero_set_check() {
    local TDIR41
    TDIR41=$(mktemp -d)
    trap 'rm -rf "$TDIR41"' RETURN
    # 3 epics: 0, 1, and 2 children respectively
    make_v3_ticket "$TDIR41" "epic-zero-ch"  "epic"  "open" "1" "" "Epic Zero Children"
    make_v3_ticket "$TDIR41" "epic-one-ch"   "epic"  "open" "2" "" "Epic One Child"
    make_v3_ticket "$TDIR41" "epic-two-ch"   "epic"  "open" "3" "" "Epic Two Children"
    make_v3_ticket "$TDIR41" "story-one"     "story" "open" "2" "" "Story One"  "epic-one-ch"
    make_v3_ticket "$TDIR41" "story-two-a"   "story" "open" "2" "" "Story TwoA" "epic-two-ch"
    make_v3_ticket "$TDIR41" "story-two-b"   "story" "open" "2" "" "Story TwoB" "epic-two-ch"

    local out41
    out41=$(TICKETS_TRACKER_DIR="$TDIR41" bash "$SCRIPT" --max-children=0 2>/dev/null)
    # Only epic-zero-ch (0 children) must appear; the others must be excluded.
    # If 0 is mishandled as unset, all epics will appear — this test catches that bug.
    [[ "$out41" == *epic-zero-ch* ]]  || return 1
    ! [[ "$out41" == *epic-one-ch* ]]  || return 1
    ! [[ "$out41" == *epic-two-ch* ]]  || return 1
}
if test_max_children_zero_set_check; then
    echo "  PASS: --max-children=0 correctly treats 0 as a set value (not unset)"
    (( PASS++ ))
else
    echo "  FAIL: --max-children=0 treated 0 as unset — epics with children appeared in output" >&2
    (( FAIL++ ))
fi

# ── Test 42: no --min-children/--max-children flags = existing behavior unchanged ─
echo "Test 42: test_min_children_backward_compat — no child-count flags leaves existing behavior unchanged"
test_min_children_backward_compat() {
    local TDIR42
    TDIR42=$(mktemp -d)
    trap 'rm -rf "$TDIR42"' RETURN
    # 3 epics with 0, 1, and 2 children; without filters ALL should appear
    make_v3_ticket "$TDIR42" "epic-bc-zero" "epic"  "open" "1" "" "Backward Compat Zero"
    make_v3_ticket "$TDIR42" "epic-bc-one"  "epic"  "open" "2" "" "Backward Compat One"
    make_v3_ticket "$TDIR42" "epic-bc-two"  "epic"  "open" "3" "" "Backward Compat Two"
    make_v3_ticket "$TDIR42" "story-bc1"    "story" "open" "2" "" "Story BC1" "epic-bc-one"
    make_v3_ticket "$TDIR42" "story-bc2a"   "story" "open" "2" "" "Story BC2a" "epic-bc-two"
    make_v3_ticket "$TDIR42" "story-bc2b"   "story" "open" "2" "" "Story BC2b" "epic-bc-two"

    local out42
    out42=$(TICKETS_TRACKER_DIR="$TDIR42" bash "$SCRIPT" 2>/dev/null)
    # All 3 epics must appear (no child-count filtering when flags are absent)
    [[ "$out42" == *epic-bc-zero* ]] || return 1
    [[ "$out42" == *epic-bc-one* ]]  || return 1
    [[ "$out42" == *epic-bc-two* ]]  || return 1
}
if test_min_children_backward_compat; then
    echo "  PASS: existing behavior preserved when no child-count flags are used"
    (( PASS++ ))
else
    echo "  FAIL: child-count filtering interfered with no-flag (backward-compat) behavior" >&2
    (( FAIL++ ))
fi

# ── Test 43: --all + --min-children work together ────────────────────────────
echo "Test 43: test_flags_combined_with_all — --all and --min-children work together"
test_flags_combined_with_all() {
    local TDIR43
    TDIR43=$(mktemp -d)
    trap 'rm -rf "$TDIR43"' RETURN
    # epic-all-ch: open, has 1 child (should appear with --all --min-children=1)
    # epic-all-noch: open, no children (filtered by --min-children=1)
    # epic-all-blocked: open, blocked by task-blk, has 1 child (should appear as BLOCKED
    #                   with --all, and pass --min-children=1 filter)
    make_v3_ticket "$TDIR43" "epic-all-ch"      "epic"  "open" "1" ""        "Epic All With Child"
    make_v3_ticket "$TDIR43" "epic-all-noch"    "epic"  "open" "2" ""        "Epic All No Child"
    make_v3_ticket "$TDIR43" "epic-all-blocked" "epic"  "open" "3" "task-blk" "Epic All Blocked With Child"
    make_v3_ticket "$TDIR43" "task-blk"         "task"  "open" "2" ""        "Task Blocker"
    make_v3_ticket "$TDIR43" "story-all1"       "story" "open" "2" ""        "Story All1" "epic-all-ch"
    make_v3_ticket "$TDIR43" "story-all2"       "story" "open" "2" ""        "Story All2" "epic-all-blocked"

    local out43
    out43=$(TICKETS_TRACKER_DIR="$TDIR43" bash "$SCRIPT" --all --min-children=1 2>/dev/null)
    # epic-all-ch (1 child, unblocked) must appear
    [[ "$out43" == *epic-all-ch* ]] || return 1
    # epic-all-noch (0 children) must NOT appear
    ! [[ "$out43" == *epic-all-noch* ]] || return 1
    # epic-all-blocked (1 child, blocked) must appear as BLOCKED (--all includes blocked epics)
    [[ "$out43" =~ BLOCKED.*epic-all-blocked ]] || return 1
}
if test_flags_combined_with_all; then
    echo "  PASS: --all and --min-children=1 work correctly together"
    (( PASS++ ))
else
    echo "  FAIL: --all and --min-children=1 combination did not produce expected output" >&2
    (( FAIL++ ))
fi

# ── Test 44: large ticket index does not trigger ARG_MAX (exit 126) ──────────
echo "Test 44: large ticket index does not produce ARG_MAX error (exit 126)"
test_large_index_no_arg_max() {
    local TDIR44
    TDIR44=$(mktemp -d)
    trap 'rm -rf "$TDIR44"' RETURN

    # Generate 500 epic ticket directories using a single python3 call to avoid
    # per-ticket subprocess overhead. Each ticket has a long title (~200 chars)
    # to produce a large index (300KB+) that would previously exceed ARG_MAX when
    # passed via environment variables.
    python3 - "$TDIR44" <<'PYEOF'
import json, os, sys
tracker_dir = sys.argv[1]
long_suffix = "x" * 180  # pad title to ~200 chars to inflate index size
for i in range(500):
    tid = f"epic-large-{i:04d}"
    tdir = os.path.join(tracker_dir, tid)
    os.makedirs(tdir, exist_ok=True)
    create_event = {
        "timestamp": 1000000001,
        "uuid": f"aaaa-{tid}",
        "event_type": "CREATE",
        "data": {
            "ticket_type": "epic",
            "title": f"Large Index Epic {i:04d} {long_suffix}",
            "priority": (i % 5)
        }
    }
    with open(os.path.join(tdir, f"1000000001-aaaa-CREATE.json"), "w") as f:
        json.dump(create_event, f)
PYEOF
    [ $? -eq 0 ] || return 1

    local out44
    local exit_code44
    out44=$(TICKETS_TRACKER_DIR="$TDIR44" SPRINT_MAX_RETRIES=0 bash "$SCRIPT" 2>/dev/null)
    exit_code44=$?

    # Exit 126 means execve() ARG_MAX was exceeded — the regression we guard against.
    # Valid exit codes: 0 (epics found), 1 (no open epics), 2 (all blocked).
    if [ "$exit_code44" -eq 126 ]; then
        echo "    exit code was 126 (Argument list too long) — ARG_MAX regression detected" >&2
        return 1
    fi

    # At least one of the generated epics must appear in the output, confirming the
    # large index was processed rather than silently truncated or errored out.
    # Use grep on a file to avoid SIGPIPE (exit 141) from pipefail when grep -q
    # closes the pipe early after finding the first match in a large output.
    local tmpout
    tmpout=$(mktemp)
    printf '%s' "$out44" > "$tmpout"
    grep -q "epic-large-" "$tmpout"
    local grep_rc=$?
    rm -f "$tmpout"
    [ "$grep_rc" -eq 0 ] || return 1
}
if test_large_index_no_arg_max; then
    echo "  PASS: large ticket index processed without ARG_MAX error"
    (( PASS++ ))
else
    echo "  FAIL: large ticket index triggered ARG_MAX or produced no output" >&2
    (( FAIL++ ))
fi

# ── Helper: create v3 ticket with tags ───────────────────────────────────────
# make_v3_ticket_tagged: like make_v3_ticket but accepts a 9th arg: space-separated tags list.
# Tags are passed as a JSON array in the CREATE event data.
make_v3_ticket_tagged() {
    local tracker_dir="$1" id="$2" type="$3" status="$4" priority="$5"
    local deps_raw="$6" title="$7" parent="${8:-}" tags_raw="${9:-}"

    mkdir -p "$tracker_dir/$id"

    # CREATE event (with optional tags)
    local ts=1000000001
    local create_data
    create_data=$(python3 -c "
import json, sys
d = {'ticket_type': sys.argv[1], 'title': sys.argv[2], 'priority': int(sys.argv[3])}
if sys.argv[4]:
    d['parent_id'] = sys.argv[4]
if sys.argv[5]:
    d['tags'] = sys.argv[5].split()
print(json.dumps(d))
" "$type" "$title" "$priority" "$parent" "$tags_raw")

    cat > "$tracker_dir/$id/${ts}-aaaa-CREATE.json" << EOF
{"timestamp": ${ts}, "uuid": "aaaa-${id}", "event_type": "CREATE", "data": ${create_data}}
EOF

    # STATUS event (if not open)
    if [ "$status" != "open" ]; then
        local ts2=1000000002
        cat > "$tracker_dir/$id/${ts2}-bbbb-STATUS.json" << EOF
{"timestamp": ${ts2}, "uuid": "bbbb-${id}", "event_type": "STATUS", "data": {"status": "${status}"}}
EOF
    fi

    # LINK events for each dependency
    if [ -n "$deps_raw" ]; then
        local ts3=1000000003
        local dep_idx=0
        for dep_id in $deps_raw; do
            dep_idx=$(( dep_idx + 1 ))
            local link_ts=$(( ts3 + dep_idx ))
            cat > "$tracker_dir/$id/${link_ts}-link${dep_idx}-${id}-LINK.json" << EOF
{"timestamp": ${link_ts}, "uuid": "link${dep_idx}-${id}", "event_type": "LINK", "data": {"target_id": "${dep_id}", "relation": "depends_on"}}
EOF
        done
    fi
}

# ── Test 45: --has-tag positive match — both tagged epics returned ────────────
echo "Test 45: test_has_tag_positive_match — --has-tag returns only epics with that tag"
test_has_tag_positive_match() {
    local TDIR45
    TDIR45=$(mktemp -d)
    trap 'rm -rf "$TDIR45"' RETURN

    # 2 epics with target tag "sprint-ready", 1 without any tag
    make_v3_ticket_tagged "$TDIR45" "epic-tag-a" "epic" "open" "1" "" "Tagged Epic A" "" "sprint-ready"
    make_v3_ticket_tagged "$TDIR45" "epic-tag-b" "epic" "open" "2" "" "Tagged Epic B" "" "sprint-ready"
    make_v3_ticket_tagged "$TDIR45" "epic-notag" "epic" "open" "3" "" "Untagged Epic"  "" ""

    local out45
    out45=$(TICKETS_TRACKER_DIR="$TDIR45" bash "$SCRIPT" --has-tag=sprint-ready 2>/dev/null)

    # Both tagged epics must appear
    [[ "$out45" == *epic-tag-a* ]] || return 1
    [[ "$out45" == *epic-tag-b* ]] || return 1
    # Untagged epic must NOT appear
    ! [[ "$out45" == *epic-notag* ]] || return 1
}
if test_has_tag_positive_match; then
    echo "  PASS: --has-tag returns both epics with the tag, excludes untagged"
    (( PASS++ ))
else
    echo "  FAIL: --has-tag did not filter correctly (positive match)" >&2
    TDIR45_DBG=$(mktemp -d)
    make_v3_ticket_tagged "$TDIR45_DBG" "epic-tag-a" "epic" "open" "1" "" "Tagged Epic A" "" "sprint-ready"
    make_v3_ticket_tagged "$TDIR45_DBG" "epic-tag-b" "epic" "open" "2" "" "Tagged Epic B" "" "sprint-ready"
    make_v3_ticket_tagged "$TDIR45_DBG" "epic-notag" "epic" "open" "3" "" "Untagged Epic"  "" ""
    actual_out45=$(TICKETS_TRACKER_DIR="$TDIR45_DBG" bash "$SCRIPT" --has-tag=sprint-ready 2>/dev/null || true)
    echo "  Output: $actual_out45" >&2
    rm -rf "$TDIR45_DBG"
    (( FAIL++ ))
fi

# ── Test 46: --has-tag negative match — epic without tag excluded ─────────────
echo "Test 46: test_has_tag_negative_match — --has-tag excludes epic that lacks the tag"
test_has_tag_negative_match() {
    local TDIR46
    TDIR46=$(mktemp -d)
    trap 'rm -rf "$TDIR46"' RETURN

    # 1 epic with "sprint-ready", 1 with a different tag, 1 with no tags
    make_v3_ticket_tagged "$TDIR46" "epic-match"    "epic" "open" "1" "" "Matching Epic"    "" "sprint-ready"
    make_v3_ticket_tagged "$TDIR46" "epic-other-tag" "epic" "open" "2" "" "Other Tag Epic"  "" "backlog"
    make_v3_ticket_tagged "$TDIR46" "epic-no-tag"   "epic" "open" "3" "" "No Tag Epic"      "" ""

    local out46
    out46=$(TICKETS_TRACKER_DIR="$TDIR46" bash "$SCRIPT" --has-tag=sprint-ready 2>/dev/null)

    # Only epic-match must appear
    [[ "$out46" == *epic-match* ]] || return 1
    # Other-tag and no-tag epics must NOT appear
    ! [[ "$out46" == *epic-other-tag* ]] || return 1
    ! [[ "$out46" == *epic-no-tag* ]] || return 1
}
if test_has_tag_negative_match; then
    echo "  PASS: --has-tag excludes epics with wrong or no tags"
    (( PASS++ ))
else
    echo "  FAIL: --has-tag did not exclude epics missing the tag" >&2
    TDIR46_DBG=$(mktemp -d)
    make_v3_ticket_tagged "$TDIR46_DBG" "epic-match"     "epic" "open" "1" "" "Matching Epic"   "" "sprint-ready"
    make_v3_ticket_tagged "$TDIR46_DBG" "epic-other-tag" "epic" "open" "2" "" "Other Tag Epic"  "" "backlog"
    make_v3_ticket_tagged "$TDIR46_DBG" "epic-no-tag"    "epic" "open" "3" "" "No Tag Epic"     "" ""
    actual_out46=$(TICKETS_TRACKER_DIR="$TDIR46_DBG" bash "$SCRIPT" --has-tag=sprint-ready 2>/dev/null || true)
    echo "  Output: $actual_out46" >&2
    rm -rf "$TDIR46_DBG"
    (( FAIL++ ))
fi

# ── Test 47: --has-tag with empty-tags epic — excluded ───────────────────────
echo "Test 47: test_has_tag_empty_tags — epic with empty tags list is excluded by --has-tag"
test_has_tag_empty_tags() {
    local TDIR47
    TDIR47=$(mktemp -d)
    trap 'rm -rf "$TDIR47"' RETURN

    # Epic with the target tag and epic with explicitly empty tags
    make_v3_ticket_tagged "$TDIR47" "epic-with-tag"    "epic" "open" "1" "" "Epic With Tag"   "" "myfeature"
    make_v3_ticket_tagged "$TDIR47" "epic-empty-tags"  "epic" "open" "2" "" "Epic Empty Tags" "" ""

    local out47
    out47=$(TICKETS_TRACKER_DIR="$TDIR47" bash "$SCRIPT" --has-tag=myfeature 2>/dev/null)

    # Only epic-with-tag must appear
    [[ "$out47" == *epic-with-tag* ]] || return 1
    # Epic with empty tags must NOT appear
    ! [[ "$out47" == *epic-empty-tags* ]] || return 1
}
if test_has_tag_empty_tags; then
    echo "  PASS: --has-tag correctly excludes epic with empty tags list"
    (( PASS++ ))
else
    echo "  FAIL: --has-tag included epic with empty tags list" >&2
    TDIR47_DBG=$(mktemp -d)
    make_v3_ticket_tagged "$TDIR47_DBG" "epic-with-tag"   "epic" "open" "1" "" "Epic With Tag"   "" "myfeature"
    make_v3_ticket_tagged "$TDIR47_DBG" "epic-empty-tags" "epic" "open" "2" "" "Epic Empty Tags" "" ""
    actual_out47=$(TICKETS_TRACKER_DIR="$TDIR47_DBG" bash "$SCRIPT" --has-tag=myfeature 2>/dev/null || true)
    echo "  Output: $actual_out47" >&2
    rm -rf "$TDIR47_DBG"
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
