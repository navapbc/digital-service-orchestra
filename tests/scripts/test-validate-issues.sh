#!/usr/bin/env bash
# tests/scripts/test-validate-issues.sh
# Unit tests for validate-issues.sh core validation check functions.
#
# Tests use TICKETS_DIR env var to point at fixture .tickets/ directories,
# avoiding any dependency on live ticket data.
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

# make_tickets_dir: creates a temp base dir and returns its path.
# Callers write .tickets/*.md files into $BASE/.tickets/
make_tickets_dir() {
    local base
    base=$(mktemp -d)
    _CLEANUP_DIRS+=("$base")
    mkdir -p "$base/.tickets"
    echo "$base"
}

# write_ticket BASE_DIR ID STATUS TYPE [PARENT] [TITLE] [HAS_BODY] [HAS_NOTES] [DEPS_YAML]
write_ticket() {
    local base="$1" tid="$2" status="$3" itype="$4"
    local parent="${5:-}" title="${6:-Test Ticket $tid}"
    local has_body="${7:-0}" has_notes="${8:-0}" deps_yaml="${9:-}"

    local parent_line=""
    if [[ -n "$parent" ]]; then
        parent_line="parent: $parent"
    fi

    local deps_block="deps: []"
    if [[ -n "$deps_yaml" ]]; then
        deps_block="$deps_yaml"
    fi

    {
        echo "---"
        echo "id: $tid"
        echo "status: $status"
        echo "type: $itype"
        echo "priority: 2"
        [[ -n "$parent_line" ]] && echo "$parent_line"
        echo "$deps_block"
        echo "links: []"
        echo "created: 2026-01-01T00:00:00Z"
        echo "---"
        echo "# $title"
        echo ""
        if [[ "$has_body" == "1" ]]; then
            echo "This ticket has a body description."
        fi
        if [[ "$has_notes" == "1" ]]; then
            echo ""
            echo "## Notes"
            echo "Progress: started work."
        fi
    } > "$base/.tickets/$tid.md"
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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-epic-alone" "open" "epic" "" "Childless Epic"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
for i in $(seq 1 5); do
    write_ticket "$BASE" "test-task-$i" "open" "task" "test-epic-parent" "Task $i" "1"
done
write_ticket "$BASE" "test-epic-parent" "open" "epic" "" "Parent Epic" "1"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
# Write an epic to parent the tasks (avoids orphan noise)
write_ticket "$BASE" "test-bulk-epic" "open" "epic" "" "Bulk Epic" "1"
for i in $(seq 1 302); do
    write_ticket "$BASE" "bulk-task-$i" "open" "task" "test-bulk-epic" "Bulk Task $i" "1"
done

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-orphan" "open" "task" "" "Orphaned Task" "1"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-parent-epic" "open" "epic" "" "Parent Epic" "1"
write_ticket "$BASE" "test-child-task" "open" "task" "test-parent-epic" "Child Task" "1"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-dup-epic" "open" "epic" "" "Parent Epic" "1"
write_ticket "$BASE" "test-dup-1" "open" "task" "test-dup-epic" "Duplicate Title Task" "1"
write_ticket "$BASE" "test-dup-2" "open" "task" "test-dup-epic" "Duplicate Title Task" "1"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-cp-epic" "open" "epic" "" "Parent Epic" "1"
# Child with parent field set AND a regular dep pointing at the parent (anti-pattern).
# The awk parser reads deps as an inline list: deps: [id1, id2]
# check_child_parent_deps detects when a child issue has its parent in deps[].
{
    echo "---"
    echo "id: test-cp-child"
    echo "status: open"
    echo "type: task"
    echo "priority: 2"
    echo "parent: test-cp-epic"
    echo "deps: [test-cp-epic]"
    echo "links: []"
    echo "created: 2026-01-01T00:00:00Z"
    echo "---"
    echo "# Child Task With Bad Dep"
    echo ""
    echo "This child has a dependency on its parent (anti-pattern)."
} > "$BASE/.tickets/test-cp-child.md"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-nodesc-epic" "open" "epic" "" "Parent Epic" "1"
# Task with no body (has_body=0)
write_ticket "$BASE" "test-nodesc-task" "open" "task" "test-nodesc-epic" "Task Without Description" "0"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-inp-epic" "open" "epic" "" "Parent Epic" "1"
# in_progress, has body but no notes section (has_body=1, has_notes=0)
write_ticket "$BASE" "test-inp-task" "in_progress" "task" "test-inp-epic" "In-Progress Task Without Notes" "1" "0"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

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
BASE=$(make_tickets_dir)
write_ticket "$BASE" "test-quick-epic" "open" "epic" "" "Quick Test Epic" "1"
write_ticket "$BASE" "test-quick-task" "open" "task" "test-quick-epic" "Quick Test Task" "1"

exit_code=0
TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --quick --terse 2>/dev/null || exit_code=$?

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
BASE=$(make_tickets_dir)
# Closed task with no parent — should NOT be flagged as orphan
write_ticket "$BASE" "test-closed-task" "closed" "task" "" "Closed Orphan-Looking Task" "1"

output=""
output=$(TICKETS_DIR="$BASE/.tickets" bash "$SCRIPT" --terse 2>&1) || true

if echo "$output" | grep -qiE "\[WARNING\].*test-closed-task"; then
    echo "  FAIL: closed ticket was incorrectly flagged" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
else
    echo "  PASS: closed ticket is excluded from orphan check"
    (( PASS++ ))
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
