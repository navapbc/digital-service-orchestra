#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-orphaned-tasks.sh
# Test harness for orphaned-tasks.sh (post bd-to-tk migration).
#
# Tests verify orphaned-tasks.sh uses tk/file-based ticket storage.
# GREEN phase: Run AFTER migration to confirm all pass.
#
# Tests 1-5: Structural / baseline — always pass against current script.
# Test 7 (RED): test_orphaned_tasks_uses_tickets_dir — FAILS until script reads TICKETS_DIR
# Test 8 (RED): test_orphaned_tasks_json_flag_uses_file_based_source — FAILS until file-based
#
# Usage: bash lockpick-workflow/tests/scripts/test-orphaned-tasks.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/orphaned-tasks.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-orphaned-tasks.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No args exits 0 ──────────────────────────────────────────────────
echo "Test 2: No args exits 0"
exit_code=0
bash "$SCRIPT" 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: no args exits 0"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0, got $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 3: --json flag produces valid JSON ───────────────────────────────────
echo "Test 3: --json flag produces valid JSON"
output=$(bash "$SCRIPT" --json 2>&1) || true
if echo "$output" | python3 -c "import sys,json; data=json.load(sys.stdin); assert isinstance(data, list)" 2>/dev/null; then
    echo "  PASS: --json produces valid JSON array"
    (( PASS++ ))
else
    echo "  FAIL: --json did not produce a valid JSON array" >&2
    (( FAIL++ ))
fi

# ── Test 4: No bash syntax errors ─────────────────────────────────────────────
echo "Test 4: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 5: Output is in expected format ─────────────────────────────────────
echo "Test 5: Output is in expected format"
output=$(bash "$SCRIPT" 2>&1) || true
if echo "$output" | grep -qE "none|P[0-9]|orphan" || [ -z "$output" ]; then
    echo "  PASS: output format is valid (none message, priority list, or empty)"
    (( PASS++ ))
else
    echo "  FAIL: unexpected output format: $output" >&2
    (( FAIL++ ))
fi

# ===========================================================================
# Migration verification tests (Tests 7-9)
# These tests verify tk-based behavior of orphaned-tasks.sh
# after the bd-to-tk migration.
# ===========================================================================

# ---------------------------------------------------------------------------
# Helper: make_fixture_tickets_dir
# Creates a temp .tickets/ directory with two fixture task files:
#   - orphan-task.md  (type: task, no parent relationship)
#   - child-task.md   (type: task, with a parent dep referencing an epic)
# Returns the path to the temp directory (the .tickets/ dir lives inside).
# ---------------------------------------------------------------------------
make_fixture_tickets_dir() {
    local base_dir
    base_dir=$(mktemp -d)
    local tickets_dir="$base_dir/.tickets"
    mkdir -p "$tickets_dir"

    # Orphaned task — no parent, type=task, status=open
    cat > "$tickets_dir/orphan-task.md" << 'ORPHAN_TICKET'
---
id: test-orphan-task
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
title: Orphaned Task With No Parent
---
# Orphaned Task With No Parent

This task has no parent epic.
ORPHAN_TICKET

    # Child task — has a parent-child dep pointing to an epic
    cat > "$tickets_dir/child-task.md" << 'CHILD_TICKET'
---
id: test-child-task
status: open
deps:
  - type: parent-child
    id: test-epic-parent
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
title: Child Task Belonging To Epic
---
# Child Task Belonging To Epic

This task belongs to an epic.
CHILD_TICKET

    # Parent epic — should be excluded from orphan output
    cat > "$tickets_dir/test-epic-parent.md" << 'EPIC_TICKET'
---
id: test-epic-parent
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: epic
priority: 1
title: Parent Epic
---
# Parent Epic

An epic that owns child-task.
EPIC_TICKET

    echo "$base_dir"
}

# ---------------------------------------------------------------------------
# Test 7: script respects TICKETS_DIR env var
# Script reads .tickets/ from TICKETS_DIR instead of calling bd list.
# We verify by:
#   1. Setting TICKETS_DIR to a fixture dir.
#   2. Running with --json.
#   3. Asserting the output JSON contains the fixture orphan task ID.
# ---------------------------------------------------------------------------
echo "Test 7: orphaned-tasks.sh respects TICKETS_DIR (post-migration)"
FIXTURE_BASE=$(make_fixture_tickets_dir)
FIXTURE_TICKETS_DIR="$FIXTURE_BASE/.tickets"

json_output=""
json_output=$(TICKETS_DIR="$FIXTURE_TICKETS_DIR" bash "$SCRIPT" --json 2>/dev/null) || true

tickets_dir_respected=0
if echo "$json_output" | grep -q "test-orphan-task"; then
    tickets_dir_respected=1
fi

if [ "$tickets_dir_respected" -eq 1 ]; then
    echo "  PASS: test_orphaned_tasks_uses_tickets_dir"
    (( PASS++ ))
else
    echo "  FAIL: test_orphaned_tasks_uses_tickets_dir — script did not read from TICKETS_DIR" >&2
    (( FAIL++ ))
fi

rm -rf "$FIXTURE_BASE"

# ---------------------------------------------------------------------------
# Test 8: --json flag uses file-based source (TICKETS_DIR)
# With a controlled TICKETS_DIR containing one orphan task and one child task,
# --json output must contain exactly the orphan (not the child, not the epic).
# ---------------------------------------------------------------------------
echo "Test 8: --json with TICKETS_DIR returns only orphan tasks (post-migration)"
FIXTURE_BASE=$(make_fixture_tickets_dir)
FIXTURE_TICKETS_DIR="$FIXTURE_BASE/.tickets"

json_output=""
json_output=$(TICKETS_DIR="$FIXTURE_TICKETS_DIR" bash "$SCRIPT" --json 2>/dev/null) || true

# Orphan task must appear in output
orphan_present=0
if echo "$json_output" | grep -q "test-orphan-task"; then
    orphan_present=1
fi

# Child task must NOT appear in output (it has a parent)
child_absent=1
if echo "$json_output" | grep -q "test-child-task"; then
    child_absent=0
fi

# Epic must NOT appear in output (epics are excluded)
epic_absent=1
if echo "$json_output" | grep -q "test-epic-parent"; then
    epic_absent=0
fi

json_source_correct=$(( orphan_present & child_absent & epic_absent ))

if [ "$json_source_correct" -eq 1 ]; then
    echo "  PASS: test_orphaned_tasks_json_flag_uses_file_based_source"
    (( PASS++ ))
else
    echo "  FAIL: test_orphaned_tasks_json_flag_uses_file_based_source" >&2
    if [ "$orphan_present" -eq 0 ]; then
        echo "    orphan task 'test-orphan-task' not found in output" >&2
    fi
    if [ "$child_absent" -eq 0 ]; then
        echo "    child task 'test-child-task' unexpectedly present in output" >&2
    fi
    if [ "$epic_absent" -eq 0 ]; then
        echo "    epic 'test-epic-parent' unexpectedly present in output" >&2
    fi
    (( FAIL++ ))
fi

rm -rf "$FIXTURE_BASE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
