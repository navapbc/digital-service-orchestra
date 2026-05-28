#!/usr/bin/env bash
# tests/scripts/test-audit-closure-checks-migration.sh
# Behavioral fixture test for plugins/dso/scripts/audit-closure-checks-migration.sh
#
# Testing Mode: RED — confirms the audit script does not yet exist.
# These tests MUST FAIL until audit-closure-checks-migration.sh is implemented.
#
# Test structure:
#   - 2 epics/stories LACKING a "## Closure Checks" section
#   - 1 epic ALREADY having "## Closure Checks"
#   - 1 task ticket (tasks are NOT epics/stories, should be excluded)
#
# Assertions:
#   1. Script exists and is executable
#   2. Accepts --target flag
#   3. Outputs tab-separated lines for tickets lacking ## Closure Checks
#   4. Output line format: <ticket-id>\t<type>\t<status>\t<title>
#   5. Exits 0 when some tickets need migration
#   6. Exits 1 when ALL epics/stories already have ## Closure Checks
#   7. Handles missing .tickets-tracker gracefully (exits 2 with error)
#   8. Does NOT report tasks (only epics and stories)
#   9. Does NOT report tickets already having ## Closure Checks
#
# Usage: bash tests/scripts/test-audit-closure-checks-migration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
AUDIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/audit-closure-checks-migration.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-audit-closure-checks-migration.sh ==="

# ── Suite-runner guard: skip when audit script does not exist ─────────────────
# RED tests fail by design (script not found). When auto-discovered by
# run-script-tests.sh, they would break `bash tests/run-all.sh`. Skip with
# exit 0 when audit-closure-checks-migration.sh is absent AND running under the suite runner.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$AUDIT_SCRIPT" ]; then
    echo "SKIP: audit-closure-checks-migration.sh not yet implemented (RED) — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-audit-closure-migration.XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: write an event file directly to a ticket dir ─────────────────────
# Usage: _write_event <ticket_dir> <timestamp> <uuid> <event_type> <data_json>
_write_event() {
    local ticket_dir="$1"
    local timestamp="$2"
    local uuid="$3"
    local event_type="$4"
    local data_json="$5"
    local filename="${timestamp}-${uuid}-${event_type}.json"

    python3 -c "
import json, sys
payload = {
    'timestamp': $timestamp,
    'uuid': '$uuid',
    'event_type': '$event_type',
    'env_id': '00000000-0000-4000-8000-000000000001',
    'author': 'Test User',
    'data': json.loads(sys.argv[1])
}
json.dump(payload, sys.stdout)
" "$data_json" > "$ticket_dir/$filename"
}

# ── Helper: set up a mixed fixture with epics, stories, and tasks ─────────────
# Creates:
#   - epic-lacks-closure: epic WITHOUT ## Closure Checks
#   - story-lacks-closure: story WITHOUT ## Closure Checks
#   - epic-has-closure: epic WITH ## Closure Checks (should be excluded)
#   - task-no-closure: task WITHOUT ## Closure Checks (tasks excluded from output)
_setup_mixed_fixture() {
    local tracker_dir="$1"

    # Epic 1: LACKS ## Closure Checks
    local dir1="$tracker_dir/epic-lacks-closure"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Audit epic lacking closure checks", "status": "open", "parent_id": null, "description": "## Context\n\nSome context.\n\n## Success Criteria\n- Criterion A\n- Criterion B\n\n## Dependencies\nNone"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-audit001001" "CREATE" "$desc1"

    # Story 1: LACKS ## Closure Checks
    local dir2="$tracker_dir/story-lacks-closure"
    mkdir -p "$dir2"
    local desc2
    desc2='{"ticket_type": "story", "title": "Story lacking closure checks", "status": "open", "parent_id": "epic-lacks-closure", "description": "## Description\n\nSome description.\n\n## Done Definitions\n- When complete, user sees results\n  <- Satisfies: \"Criterion A\"\n"}'
    _write_event "$dir2" "1742605200" "00000000-0000-4000-8000-audit002001" "CREATE" "$desc2"

    # Epic 2: HAS ## Closure Checks (should NOT appear in output)
    local dir3="$tracker_dir/epic-has-closure"
    mkdir -p "$dir3"
    local desc3
    desc3='{"ticket_type": "epic", "title": "Epic already with closure checks", "status": "open", "parent_id": null, "description": "## Context\n\nAlready migrated.\n\n## Success Criteria\n- Criterion Z\n\n## Closure Checks\n- Durable end-state intent here\n\n## Dependencies\nNone"}'
    _write_event "$dir3" "1742605300" "00000000-0000-4000-8000-audit003001" "CREATE" "$desc3"

    # Task: LACKS ## Closure Checks but is a TASK — should NOT appear in output
    local dir4="$tracker_dir/task-no-closure"
    mkdir -p "$dir4"
    local desc4
    desc4='{"ticket_type": "task", "title": "A task without closure checks", "status": "open", "parent_id": "story-lacks-closure", "description": "## Description\n\nTask description.\n\n## Acceptance Criteria\n- AC1\n"}'
    _write_event "$dir4" "1742605400" "00000000-0000-4000-8000-audit004001" "CREATE" "$desc4"
}

# ── Helper: set up all-migrated fixture ──────────────────────────────────────
# All epics/stories already have ## Closure Checks
_setup_all_migrated_fixture() {
    local tracker_dir="$1"

    local dir1="$tracker_dir/epic-all-done-1"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic all migrated 1", "status": "open", "parent_id": null, "description": "## Context\n\nContext.\n\n## Success Criteria\n- SC1\n\n## Closure Checks\n- End-state item\n"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-allm001001" "CREATE" "$desc1"

    local dir2="$tracker_dir/story-all-done-2"
    mkdir -p "$dir2"
    local desc2
    desc2='{"ticket_type": "story", "title": "Story all migrated 2", "status": "open", "parent_id": "epic-all-done-1", "description": "## Description\n\nDesc.\n\n## Done Definitions\n- DD1\n\n## Closure Checks\n- End-state item 2\n"}'
    _write_event "$dir2" "1742605200" "00000000-0000-4000-8000-allm002001" "CREATE" "$desc2"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable (RED gate)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: audit script exists and is executable"
test_audit_script_exists_and_executable() {
    if [ -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit-closure-checks-migration.sh exists" "exists" "exists"
    else
        assert_eq "audit-closure-checks-migration.sh exists" "exists" "missing"
    fi
    if [ -x "$AUDIT_SCRIPT" ]; then
        assert_eq "audit-closure-checks-migration.sh is executable" "executable" "executable"
    else
        assert_eq "audit-closure-checks-migration.sh is executable" "executable" "not-executable"
    fi
}
test_audit_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: Accepts --target flag
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: script accepts --target flag"
test_accepts_target_flag() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Running with --target should not cause an "unknown argument" error
    local exit_code=0
    bash "$AUDIT_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    # Should exit 0 (tickets needing migration found) not 2 (error) from bad flag
    assert_ne "accepts --target flag (does not exit 2 for bad flag)" "2" "$exit_code"

    assert_pass_if_clean "test_accepts_target_flag"
}
test_accepts_target_flag

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Exits 0 when tickets need migration
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: exits 0 when some tickets lack ## Closure Checks"
test_exits_0_when_tickets_need_migration() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local exit_code=0
    bash "$AUDIT_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    assert_eq "exits 0 when tickets need migration" "0" "$exit_code"

    assert_pass_if_clean "test_exits_0_when_tickets_need_migration"
}
test_exits_0_when_tickets_need_migration

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Exits 1 when all epics/stories already migrated
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: exits 1 when all tickets already have ## Closure Checks"
test_exits_1_when_all_migrated() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_all_migrated_fixture "$repo/.tickets-tracker"

    local exit_code=0
    local stdout
    stdout=$(bash "$AUDIT_SCRIPT" --target "$repo" 2>/dev/null) || exit_code=$?

    assert_eq "exits 1 when all tickets already migrated" "1" "$exit_code"
    # Distinguish intentional exit 1 (all migrated → empty output) from set -e abort (also exit 1)
    assert_eq "stdout empty when all migrated (not a crash)" "" "$stdout"

    assert_pass_if_clean "test_exits_1_when_all_migrated"
}
test_exits_1_when_all_migrated

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: Exits 2 when .tickets-tracker is missing
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: exits 2 when .tickets-tracker is absent"
test_exits_2_when_tracker_missing() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-audit-no-tracker.XXXXXX")
    _CLEANUP_DIRS+=("$tmp")

    # A bare git repo with no .tickets-tracker
    git init -q -b main "$tmp/bare-repo" 2>/dev/null
    git -C "$tmp/bare-repo" config user.email "test@test.com"
    git -C "$tmp/bare-repo" config user.name "Test"
    git -C "$tmp/bare-repo" config commit.gpgsign false
    echo "init" > "$tmp/bare-repo/README.md"
    git -C "$tmp/bare-repo" add -A
    git -C "$tmp/bare-repo" commit -q -m "init"

    local exit_code=0
    bash "$AUDIT_SCRIPT" --target "$tmp/bare-repo" >/dev/null 2>&1 || exit_code=$?

    assert_eq "exits 2 when .tickets-tracker absent" "2" "$exit_code"

    assert_pass_if_clean "test_exits_2_when_tracker_missing"
}
test_exits_2_when_tracker_missing

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: Output lines are tab-separated with correct fields
# ═══════════════════════════════════════════════════════════════════════════════
printf 'Test 6: output format is tab-separated <ticket-id>\\t<type>\\t<status>\\t<title>\n'
test_output_format_tab_separated() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$AUDIT_SCRIPT" --target "$repo" 2>/dev/null) || true

    # Check at least one output line exists
    local line_count
    line_count=$(echo "$output" | grep -c $'\t' 2>/dev/null || echo "0")
    assert_ne "output contains tab-separated lines" "0" "$line_count"

    # Check first line has correct tab-separated structure: id\ttype\tstatus\ttitle
    local first_line
    first_line=$(echo "$output" | head -1)
    local field_count
    field_count=$(echo "$first_line" | awk -F'\t' '{print NF}')
    assert_eq "output line has 4 tab-separated fields" "4" "$field_count"

    # Check the 2nd field (type) is epic or story (not task)
    local line_type
    line_type=$(echo "$first_line" | awk -F'\t' '{print $2}')
    if [ "$line_type" = "epic" ] || [ "$line_type" = "story" ]; then
        assert_eq "output type field is epic or story" "$line_type" "$line_type"
    else
        assert_eq "output type field is epic or story" "epic or story" "$line_type"
    fi

    assert_pass_if_clean "test_output_format_tab_separated"
}
test_output_format_tab_separated

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: Output contains ticket-id for lacking epics/stories
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: output contains the correct ticket IDs (epic-lacks-closure, story-lacks-closure)"
test_output_contains_correct_ticket_ids() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$AUDIT_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_contains "output contains epic-lacks-closure" \
        "epic-lacks-closure" "$output"
    assert_contains "output contains story-lacks-closure" \
        "story-lacks-closure" "$output"

    assert_pass_if_clean "test_output_contains_correct_ticket_ids"
}
test_output_contains_correct_ticket_ids

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: Output does NOT include already-migrated tickets
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: output does NOT include tickets that already have ## Closure Checks"
test_output_excludes_already_migrated() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$AUDIT_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_not_contains "output excludes epic-has-closure (already migrated)" \
        "epic-has-closure" "$output"

    assert_pass_if_clean "test_output_excludes_already_migrated"
}
test_output_excludes_already_migrated

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: Output does NOT include task tickets (only epics and stories)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 9: output does NOT include task tickets"
test_output_excludes_tasks() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$AUDIT_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_not_contains "output excludes task-no-closure (task type)" \
        "task-no-closure" "$output"

    assert_pass_if_clean "test_output_excludes_tasks"
}
test_output_excludes_tasks

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: Output line includes ticket title in 4th field
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 10: output line 4th field contains ticket title"
test_output_line_includes_title() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$AUDIT_SCRIPT" --target "$repo" 2>/dev/null) || true

    # epic-lacks-closure has title "Audit epic lacking closure checks"
    # Check it appears in the output
    assert_contains "output contains epic title text" \
        "Audit epic lacking closure checks" "$output"

    assert_pass_if_clean "test_output_line_includes_title"
}
test_output_line_includes_title

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
