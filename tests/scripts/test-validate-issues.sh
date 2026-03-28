#!/usr/bin/env bash
# tests/scripts/test-validate-issues.sh
# Unit tests for validate-issues.sh core validation check functions.
#
# Tests use TICKET_CMD mock scripts to inject fixture data without any
# dependency on live ticket data or v2 markdown file fixtures.
#
# Checks covered:
#   - check_empty_epics         (verbose-only, no MINOR/WARNING for childless epics)
#   - check_ticket_count        (warn >=300, major >=600)
#   - check_orphaned_tasks      (open tasks with no parent)
#   - check_duplicate_titles    (MINOR on dup titles)
#   - check_child_parent_deps   (CRITICAL on child->parent dep)
#   - check_missing_descriptions (WARNING on tasks without body text)
#   - check_in_progress_without_notes (WARNING on in_progress tasks with no notes)
#   - Script syntax
#   - --quick mode runs without error
#   - Exit code reflects health score
#
# Usage: bash tests/scripts/test-validate-issues.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/validate-issues.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-validate-issues.sh ==="

# ── Fixture helpers ───────────────────────────────────────────────────────────

# make_ticket_cmd TICKETS_JSON
# Creates a temp directory with a mock `ticket` script that returns the given
# JSON array from `ticket list`. Returns the path to the mock script.
# Usage: TICKET_CMD=$(make_ticket_cmd '[...]')  TICKET_CMD="$mock" bash ...
make_ticket_cmd() {
    local tickets_json="${1:-[]}"
    local mock_dir
    mock_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$mock_dir")
    local mock_script="$mock_dir/ticket"
    # Write mock ticket script
    cat > "$mock_script" << MOCK_TICKET
#!/usr/bin/env bash
SUBCMD="\${1:-}"
case "\$SUBCMD" in
    list) echo '${tickets_json//\'/\'\\\'\'}' ; exit 0 ;;
    *) exit 0 ;;
esac
MOCK_TICKET
    chmod +x "$mock_script"
    echo "$mock_script"
}

# make_ticket_json ID STATUS TYPE [PARENT] [TITLE] [HAS_BODY] [HAS_NOTES] [DEPS_JSON]
# Returns a single ticket JSON object (without outer brackets).
make_ticket_json() {
    local tid="$1" status="$2" itype="$3"
    local parent="${4:-}" title="${5:-Test Ticket $1}"
    local has_body="${6:-0}" has_notes="${7:-0}" deps_json="${8:-[]}"

    local parent_val="null"
    if [[ -n "$parent" ]]; then
        parent_val="\"$parent\""
    fi

    local description_val='""'
    if [[ "$has_body" == "1" ]]; then
        description_val='"yes"'
    fi

    local notes_val='""'
    if [[ "$has_notes" == "1" ]]; then
        notes_val='"yes"'
    fi

    echo "{\"ticket_id\":\"$tid\",\"status\":\"$status\",\"ticket_type\":\"$itype\",\"title\":\"$title\",\"parent_id\":$parent_val,\"description\":$description_val,\"notes\":$notes_val,\"deps\":$deps_json,\"created_at\":\"2026-01-01T00:00:00Z\"}"
}

# ── Test 1: Script exists and is executable ───────────────────────────────────
echo "Test 1: Script exists and is executable"
if [[ -x "$SCRIPT" ]]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: $SCRIPT is not executable or does not exist" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found in $SCRIPT" >&2
    (( FAIL++ ))
fi

# ── Test 3: test_empty_epic / test_childless_epic ────────────────────────────
# check_empty_epics: childless epic produces no MINOR/WARNING.
# The acceptance criteria specify that empty epics only emit verbose output,
# not MINOR or WARNING issues.
echo "Test 3: check_empty_epics — childless epic not flagged as MINOR or WARNING"
TICKETS_JSON=$(make_ticket_json "test-epic-alone" "open" "epic" "" "Childless Epic")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$TICKETS_JSON]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[MINOR\].*test-epic-alone|\[WARNING\].*test-epic-alone"; then
    echo "  FAIL: childless epic emitted MINOR or WARNING (should be verbose-only)" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: childless epic did not generate MINOR or WARNING issue"
    (( PASS++ ))
fi

# ── Tests 4-5: test_ticket_count (thresholds: warn>=300, error>=600) ─────────
echo "Test 4: check_ticket_count — small ticket count produces no ticket-count warning"
PARENT_JSON=$(make_ticket_json "test-epic-parent" "open" "epic" "" "Parent Epic" "1")
TICKETS_ARRAY="[$PARENT_JSON"
for i in $(seq 1 5); do
    T=$(make_ticket_json "test-task-$i" "open" "task" "test-epic-parent" "Task $i" "1")
    TICKETS_ARRAY="$TICKETS_ARRAY,$T"
done
TICKETS_ARRAY="$TICKETS_ARRAY]"
MOCK_TICKET_CMD=$(make_ticket_cmd "$TICKETS_ARRAY")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[MAJOR\].*ticket count|\[WARNING\].*ticket count"; then
    echo "  FAIL: small ticket count triggered unexpected ticket-count warning" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: small ticket count produced no ticket-count warning"
    (( PASS++ ))
fi

# ── Test 5: check_ticket_count — >= 300 tickets produces WARNING ─────────────
echo "Test 5: check_ticket_count — 300+ tickets triggers WARNING"
BULK_EPIC=$(make_ticket_json "test-bulk-epic" "open" "epic" "" "Bulk Epic" "1")
TICKETS_ARRAY="[$BULK_EPIC"
for i in $(seq 1 302); do
    T=$(make_ticket_json "bulk-task-$i" "open" "task" "test-bulk-epic" "Bulk Task $i" "1")
    TICKETS_ARRAY="$TICKETS_ARRAY,$T"
done
TICKETS_ARRAY="$TICKETS_ARRAY]"
MOCK_TICKET_CMD=$(make_ticket_cmd "$TICKETS_ARRAY")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*ticket count|\[MAJOR\].*ticket count"; then
    echo "  PASS: 300+ tickets produced ticket-count WARNING"
    (( PASS++ ))
else
    echo "  FAIL: 300+ tickets did not trigger ticket-count WARNING" >&2
    echo "  Output (first 20 lines): $(echo "$output" | head -20)" >&2
    (( FAIL++ ))
fi

# ── Test 6: check_orphaned_tasks — open task with no parent produces WARNING ──
echo "Test 6: check_orphaned_tasks — orphan task produces WARNING"
ORPHAN_JSON=$(make_ticket_json "test-orphan" "open" "task" "" "Orphaned Task" "1")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$ORPHAN_JSON]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*test-orphan|\[WARNING\].*[Oo]rphan"; then
    echo "  PASS: orphaned task produced WARNING"
    (( PASS++ ))
else
    echo "  FAIL: orphaned task did not produce WARNING" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
fi

# ── Test 7: check_orphaned_tasks — task with parent is NOT orphaned ───────────
echo "Test 7: check_orphaned_tasks — task with parent is not flagged as orphan"
PARENT_EPIC=$(make_ticket_json "test-parent-epic" "open" "epic" "" "Parent Epic" "1")
CHILD_TASK=$(make_ticket_json "test-child-task" "open" "task" "test-parent-epic" "Child Task" "1")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$PARENT_EPIC,$CHILD_TASK]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*test-child-task.*[Oo]rphan|\[WARNING\].*[Oo]rphan.*test-child-task"; then
    echo "  FAIL: child task with parent was incorrectly flagged as orphan" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: child task with parent is not flagged as orphan"
    (( PASS++ ))
fi

# ── Test 8: check_duplicate_titles — duplicate titles produce MINOR ───────────
echo "Test 8: check_duplicate_titles — duplicate title produces MINOR"
DUP_EPIC=$(make_ticket_json "test-dup-epic" "open" "epic" "" "Parent Epic" "1")
DUP_1=$(make_ticket_json "test-dup-1" "open" "task" "test-dup-epic" "Duplicate Title Task" "1")
DUP_2=$(make_ticket_json "test-dup-2" "open" "task" "test-dup-epic" "Duplicate Title Task" "1")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$DUP_EPIC,$DUP_1,$DUP_2]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[MINOR\].*[Dd]uplicate"; then
    echo "  PASS: duplicate titles produced MINOR"
    (( PASS++ ))
else
    echo "  FAIL: duplicate titles did not produce MINOR" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
fi

# ── Test 9: check_child_parent_deps — child->parent dep produces CRITICAL ─────
echo "Test 9: check_child_parent_deps — child depends on parent produces CRITICAL"
CP_EPIC=$(make_ticket_json "test-cp-epic" "open" "epic" "" "Parent Epic" "1")
# Child with parent_id set AND a dep (blocks type) pointing at the parent — anti-pattern.
CP_CHILD=$(python3 -c "
import json
t = {
    'ticket_id': 'test-cp-child',
    'status': 'open',
    'ticket_type': 'task',
    'title': 'Child Task With Bad Dep',
    'parent_id': 'test-cp-epic',
    'description': 'yes',
    'notes': '',
    'deps': [{'target_id': 'test-cp-epic', 'relation': 'blocks'}],
    'created_at': '2026-01-01T00:00:00Z',
}
print(json.dumps(t))
")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$CP_EPIC,$CP_CHILD]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[CRITICAL\].*test-cp-child|\[CRITICAL\].*[Cc]hild.*parent"; then
    echo "  PASS: child->parent dep produced CRITICAL"
    (( PASS++ ))
else
    echo "  FAIL: child->parent dep did not produce CRITICAL" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
fi

# ── Test 10: check_missing_descriptions — task without body produces WARNING ──
echo "Test 10: check_missing_descriptions — task without description produces WARNING"
NODESC_EPIC=$(make_ticket_json "test-nodesc-epic" "open" "epic" "" "Parent Epic" "1")
# Task with no body (has_body=0)
NODESC_TASK=$(make_ticket_json "test-nodesc-task" "open" "task" "test-nodesc-epic" "Task Without Description" "0")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$NODESC_EPIC,$NODESC_TASK]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*test-nodesc-task|\[WARNING\].*[Mm]issing description"; then
    echo "  PASS: task without description produced WARNING"
    (( PASS++ ))
else
    echo "  FAIL: task without description did not produce WARNING" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
fi

# ── Test 11: check_in_progress_without_notes — in_progress task without notes ─
echo "Test 11: check_in_progress_without_notes — in_progress task without notes produces WARNING"
INP_EPIC=$(make_ticket_json "test-inp-epic" "open" "epic" "" "Parent Epic" "1")
# in_progress, has body but no notes section (has_body=1, has_notes=0)
INP_TASK=$(make_ticket_json "test-inp-task" "in_progress" "task" "test-inp-epic" "In-Progress Task Without Notes" "1" "0")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$INP_EPIC,$INP_TASK]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*test-inp-task|\[WARNING\].*[Ii]n.progress.*notes|\[WARNING\].*notes.*in.progress"; then
    echo "  PASS: in_progress task without notes produced WARNING"
    (( PASS++ ))
else
    echo "  FAIL: in_progress task without notes did not produce WARNING" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
fi

# ── Test 12: --quick mode runs without error ──────────────────────────────────
echo "Test 12: --quick mode runs without error on healthy fixture"
QUICK_EPIC=$(make_ticket_json "test-quick-epic" "open" "epic" "" "Quick Test Epic" "1")
QUICK_TASK=$(make_ticket_json "test-quick-task" "open" "task" "test-quick-epic" "Quick Test Task" "1")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$QUICK_EPIC,$QUICK_TASK]")

exit_code=0
TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --quick --terse 2>/dev/null || exit_code=$?

# validate-issues.sh exits with 5-score; score 5 = exit 0, score 4 = exit 1
# For a healthy fixture we expect exit 0 or 1 (not a crash/error code >= 2
# due to --quick flag being unrecognized, etc.)
if [[ $exit_code -le 1 ]]; then
    echo "  PASS: --quick mode exited cleanly (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: --quick mode returned unexpected exit code $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 13: closed tickets are excluded from all checks ─────────────────────
echo "Test 13: closed tickets are excluded from orphan check"
# Closed task with no parent — should NOT be flagged as orphan.
# Note: get_shared_issues_json skips closed tickets, so this returns an empty list.
CLOSED_TASK=$(make_ticket_json "test-closed-task" "closed" "task" "" "Closed Orphan-Looking Task" "1")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$CLOSED_TASK]")

output=""
output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*test-closed-task"; then
    echo "  FAIL: closed ticket was incorrectly flagged" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: closed ticket is excluded from orphan check"
    (( PASS++ ))
fi

# ── Test 14: integer timestamp in created_at does not crash check_orphaned_tasks
echo "Test 14: check_orphaned_tasks — integer created_at field does not cause TypeError crash"
# Ticket event files may store timestamps as Unix epoch integers rather than ISO strings.
# The check_orphaned_tasks cluster-grouping code does created[:19] on the created_at field,
# which raises TypeError when the value is an int. This test verifies the script completes
# without crashing and does not emit a Python traceback to stderr.
INT_TS_TASK=$(python3 -c "
import json
t = {
    'ticket_id': 'test-int-ts-task',
    'status': 'open',
    'ticket_type': 'task',
    'title': 'Task With Integer Timestamp',
    'parent_id': None,
    'description': 'yes',
    'notes': '',
    'deps': [],
    'created_at': 1748390400,
}
print(json.dumps(t))
")
MOCK_TICKET_CMD=$(make_ticket_cmd "[$INT_TS_TASK]")

int_ts_output=""
int_ts_exit=0
int_ts_output=$(TICKET_CMD="$MOCK_TICKET_CMD" bash "$SCRIPT" --terse 2>&1) || int_ts_exit=$?

if echo "$int_ts_output" | grep -q "TypeError"; then
    echo "  FAIL: script emitted a TypeError when created_at is an integer" >&2
    echo "  Output: $int_ts_output" >&2
    (( FAIL++ ))
elif [[ $int_ts_exit -ge 5 ]]; then
    echo "  FAIL: script exited with crash-level code $int_ts_exit" >&2
    echo "  Output: $int_ts_output" >&2
    (( FAIL++ ))
else
    echo "  PASS: integer created_at did not cause a TypeError crash (exit $int_ts_exit)"
    (( PASS++ ))
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
