#!/usr/bin/env bash
# tests/scripts/test-migrate-closure-checks.sh
# Behavioral fixture test for plugins/dso/scripts/migrate-closure-checks.sh
#
# Testing Mode: GREEN — tests must pass once migrate-closure-checks.sh is implemented.
# These tests validate the bulk migration script with idempotency and resume semantics.
#
# Test structure:
#   - Mixed tickets: epics/stories with and without ## Closure Checks
#   - Verify v1.2.0 sentinel idempotency
#   - Verify resume via progress session file
#   - Verify batch processing (≤25 per batch)
#   - Verify --dry-run flag
#   - Verify stdin ticket ID list mode
#   - Verify exit codes: 0=all migrated, 1=some failed, 2=fatal error
#
# Usage: bash tests/scripts/test-migrate-closure-checks.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MIGRATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/migrate-closure-checks.sh"
PER_TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-migrate-closure-checks-v1.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-migrate-closure-checks.sh ==="

# ── Suite-runner guard: skip when script does not exist ──────────────────────
# When auto-discovered by run-script-tests.sh, RED tests would break the suite.
# Skip with exit 0 when migrate-closure-checks.sh is absent AND running under the suite runner.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "SKIP: migrate-closure-checks.sh not yet implemented — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-closure-checks.XXXXXX")
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
    local env_id="${6:-00000000-0000-4000-8000-000000000001}"
    local author="${7:-Test User}"
    local filename="${timestamp}-${uuid}-${event_type}.json"

    python3 -c "
import json, sys
payload = {
    'timestamp': $timestamp,
    'uuid': '$uuid',
    'event_type': '$event_type',
    'env_id': '$env_id',
    'author': '$author',
    'data': json.loads(sys.argv[1])
}
json.dump(payload, sys.stdout)
" "$data_json" > "$ticket_dir/$filename"
}

# ── Helper: set up a mixed fixture with epics/stories and tasks ───────────────
# Creates:
#   - epic-no-closure-01: epic WITHOUT ## Closure Checks
#   - epic-no-closure-02: epic WITHOUT ## Closure Checks
#   - story-no-closure-01: story WITHOUT ## Closure Checks
#   - epic-has-closure-01: epic WITH ## Closure Checks (should be skipped)
#   - task-no-closure-01: task WITHOUT ## Closure Checks (tasks excluded)
_setup_mixed_fixture() {
    local tracker_dir="$1"

    # Epic 1: LACKS ## Closure Checks
    local dir1="$tracker_dir/epic-no-closure-01"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic lacking Closure Checks (1)", "status": "open", "parent_id": null, "description": "## Context\n\nSome context.\n\n## Success Criteria\n- Criterion A\n- Criterion B\n\n## Dependencies\nNone"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-bulk001001" "CREATE" "$desc1"

    # Epic 2: LACKS ## Closure Checks
    local dir2="$tracker_dir/epic-no-closure-02"
    mkdir -p "$dir2"
    local desc2
    desc2='{"ticket_type": "epic", "title": "Epic lacking Closure Checks (2)", "status": "open", "parent_id": null, "description": "## Context\n\nAnother context.\n\n## Success Criteria\n- Criterion X\n\n## Approach\nSome approach."}'
    _write_event "$dir2" "1742605200" "00000000-0000-4000-8000-bulk002001" "CREATE" "$desc2"

    # Story 1: LACKS ## Closure Checks
    local dir3="$tracker_dir/story-no-closure-01"
    mkdir -p "$dir3"
    local desc3
    desc3='{"ticket_type": "story", "title": "Story lacking Closure Checks", "status": "open", "parent_id": "epic-no-closure-01", "description": "## Description\n\nStory description.\n\n## Done Definitions\n- DD1\n"}'
    _write_event "$dir3" "1742605300" "00000000-0000-4000-8000-bulk003001" "CREATE" "$desc3"

    # Epic 3: HAS ## Closure Checks — should be skipped by idempotency check
    local dir4="$tracker_dir/epic-has-closure-01"
    mkdir -p "$dir4"
    local desc4
    desc4='{"ticket_type": "epic", "title": "Epic already with Closure Checks", "status": "open", "parent_id": null, "description": "## Context\n\nAlready migrated.\n\n## Success Criteria\n- Criterion Z\n\n## Closure Checks\n- End-state item\n\n## Dependencies\nNone"}'
    _write_event "$dir4" "1742605400" "00000000-0000-4000-8000-bulk004001" "CREATE" "$desc4"

    # Task: LACKS ## Closure Checks but is a task — should NOT be processed
    local dir5="$tracker_dir/task-no-closure-01"
    mkdir -p "$dir5"
    local desc5
    desc5='{"ticket_type": "task", "title": "Task without Closure Checks", "status": "open", "parent_id": "story-no-closure-01", "description": "## Description\n\nTask description.\n\n## Acceptance Criteria\n- AC1\n"}'
    _write_event "$dir5" "1742605500" "00000000-0000-4000-8000-bulk005001" "CREATE" "$desc5"
}

# ── Helper: read current compiled description for a ticket ────────────────────
_get_ticket_description() {
    local repo="$1"
    local ticket_id="$2"
    local tracker_dir="$repo/.tickets-tracker"
    local ticket_dir="$tracker_dir/$ticket_id"
    if [ ! -d "$ticket_dir" ]; then
        echo ""
        return
    fi
    TICKETS_TRACKER_DIR="$tracker_dir" python3 "$REPO_ROOT/plugins/dso/scripts/ticket-reducer.py" "$ticket_dir" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('description',''))" 2>/dev/null || echo ""
}

# ── Helper: count ## Closure Checks occurrences in a string ──────────────────
_count_closure_checks_sections() {
    local text="$1"
    echo "$text" | grep -c '## Closure Checks' 2>/dev/null || true
}

# ── Helper: count EDIT events for a ticket ───────────────────────────────────
_count_edit_events() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -name '*-EDIT.json' 2>/dev/null | wc -l | tr -d ' '
}

# ── Helper: create a large fixture with N epics lacking ## Closure Checks ────
_setup_large_fixture() {
    local tracker_dir="$1"
    local count="${2:-30}"

    local i
    for i in $(seq 1 "$count"); do
        local padded
        padded=$(printf "%03d" "$i")
        local dir="$tracker_dir/epic-batch-test-$padded"
        mkdir -p "$dir"
        local ts
        ts=$((1742700000 + i))
        local uuid
        uuid="00000000-0000-4000-8000-large$(printf '%06d' "$i")"
        local desc
        desc="{\"ticket_type\": \"epic\", \"title\": \"Batch test epic $padded\", \"status\": \"open\", \"parent_id\": null, \"description\": \"## Context\n\nContext for epic $padded.\n\n## Success Criteria\n- SC$padded\n\"}"
        _write_event "$dir" "$ts" "$uuid" "CREATE" "$desc"
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: migrate-closure-checks.sh exists and is executable"
test_script_exists_and_executable() {
    if [ -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate-closure-checks.sh exists" "exists" "exists"
    else
        assert_eq "migrate-closure-checks.sh exists" "exists" "missing"
    fi
    if [ -x "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate-closure-checks.sh is executable" "executable" "executable"
    else
        assert_eq "migrate-closure-checks.sh is executable" "executable" "not-executable"
    fi
}
test_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: Accepts --target flag without error
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: accepts --target flag"
test_accepts_target_flag() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Running with --target should not cause an "unknown argument" error
    local exit_code=0
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    # Should not exit 2 (fatal error from bad flag parsing)
    assert_ne "accepts --target flag (no fatal error)" "2" "$exit_code"

    assert_pass_if_clean "test_accepts_target_flag"
}
test_accepts_target_flag

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Exit 0 when all tickets successfully migrated
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: exits 0 when migration completes successfully"
test_exits_0_on_success() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local exit_code=0
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    assert_eq "exits 0 on successful migration" "0" "$exit_code"

    assert_pass_if_clean "test_exits_0_on_success"
}
test_exits_0_on_success

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Mixed SC/transitional content — lacking tickets get ## Closure Checks
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: epics/stories lacking ## Closure Checks are migrated"
test_lacking_tickets_get_closure_checks() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # Epic 1 must now have ## Closure Checks
    local desc1
    desc1=$(_get_ticket_description "$repo" "epic-no-closure-01")
    local count1
    count1=$(_count_closure_checks_sections "$desc1")
    assert_eq "epic-no-closure-01: gets ## Closure Checks section" "1" "$count1"

    # Epic 2 must now have ## Closure Checks
    local desc2
    desc2=$(_get_ticket_description "$repo" "epic-no-closure-02")
    local count2
    count2=$(_count_closure_checks_sections "$desc2")
    assert_eq "epic-no-closure-02: gets ## Closure Checks section" "1" "$count2"

    # Story 1 must now have ## Closure Checks
    local desc3
    desc3=$(_get_ticket_description "$repo" "story-no-closure-01")
    local count3
    count3=$(_count_closure_checks_sections "$desc3")
    assert_eq "story-no-closure-01: gets ## Closure Checks section" "1" "$count3"

    assert_pass_if_clean "test_lacking_tickets_get_closure_checks"
}
test_lacking_tickets_get_closure_checks

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: Already-migrated tickets skipped (idempotency — v1.2.0 sentinel)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: already-migrated tickets are skipped idempotently"
test_already_migrated_skipped() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local edits_before
    edits_before=$(_count_edit_events "$repo/.tickets-tracker" "epic-has-closure-01")

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # Epic with existing ## Closure Checks must not get a new EDIT event
    local edits_after
    edits_after=$(_count_edit_events "$repo/.tickets-tracker" "epic-has-closure-01")
    assert_eq "epic-has-closure-01: no new EDIT events (idempotent skip)" "$edits_before" "$edits_after"

    # Must still have exactly 1 ## Closure Checks section (not duplicated)
    local desc
    desc=$(_get_ticket_description "$repo" "epic-has-closure-01")
    local count
    count=$(_count_closure_checks_sections "$desc")
    assert_eq "epic-has-closure-01: still exactly 1 ## Closure Checks section" "1" "$count"

    assert_pass_if_clean "test_already_migrated_skipped"
}
test_already_migrated_skipped

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: Task tickets are NOT processed (only epics and stories)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: task tickets are not processed"
test_tasks_not_processed() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    local edits_before
    edits_before=$(_count_edit_events "$repo/.tickets-tracker" "task-no-closure-01")

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    local edits_after
    edits_after=$(_count_edit_events "$repo/.tickets-tracker" "task-no-closure-01")
    assert_eq "task-no-closure-01: no EDIT events written (tasks excluded)" "$edits_before" "$edits_after"

    assert_pass_if_clean "test_tasks_not_processed"
}
test_tasks_not_processed

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: Idempotency — re-run after successful migration writes no new events
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: re-run after successful migration is idempotent (no new EDIT events)"
test_rerun_is_idempotent() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # First run — migrates all lacking tickets
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # Count EDIT events after first run
    local edits1_after_run1 edits2_after_run1 edits3_after_run1
    edits1_after_run1=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-01")
    edits2_after_run1=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-02")
    edits3_after_run1=$(_count_edit_events "$repo/.tickets-tracker" "story-no-closure-01")

    # Second run — should be a no-op (v1.2.0 sentinel present in each ticket now)
    local exit_code2=0
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code2=$?
    assert_eq "re-run exits 0" "0" "$exit_code2"

    # EDIT event counts must not have changed after second run
    local edits1_after_run2 edits2_after_run2 edits3_after_run2
    edits1_after_run2=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-01")
    edits2_after_run2=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-02")
    edits3_after_run2=$(_count_edit_events "$repo/.tickets-tracker" "story-no-closure-01")

    assert_eq "re-run: no new EDIT events on epic-no-closure-01" \
        "$edits1_after_run1" "$edits1_after_run2"
    assert_eq "re-run: no new EDIT events on epic-no-closure-02" \
        "$edits2_after_run1" "$edits2_after_run2"
    assert_eq "re-run: no new EDIT events on story-no-closure-01" \
        "$edits3_after_run1" "$edits3_after_run2"

    # Descriptions must still have exactly 1 ## Closure Checks section (not duplicated)
    local desc1
    desc1=$(_get_ticket_description "$repo" "epic-no-closure-01")
    local count1
    count1=$(_count_closure_checks_sections "$desc1")
    assert_eq "re-run: epic-no-closure-01 still has exactly 1 ## Closure Checks" "1" "$count1"

    assert_pass_if_clean "test_rerun_is_idempotent"
}
test_rerun_is_idempotent

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: Tickets with no transitional content get empty ## Closure Checks appended
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: tickets with no ## Success Criteria get ## Closure Checks appended at end"
test_no_success_criteria_gets_closure_checks_appended() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create an epic with NO ## Success Criteria section
    local tracker_dir="$repo/.tickets-tracker"
    local dir="$tracker_dir/epic-no-sc"
    mkdir -p "$dir"
    local desc
    desc='{"ticket_type": "epic", "title": "Epic with no Success Criteria", "status": "open", "parent_id": null, "description": "## Context\n\nJust a context section, no Success Criteria."}'
    _write_event "$dir" "1742606000" "00000000-0000-4000-8000-nosc001001" "CREATE" "$desc"

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    local desc_after
    desc_after=$(_get_ticket_description "$repo" "epic-no-sc")
    local count
    count=$(_count_closure_checks_sections "$desc_after")
    assert_eq "epic-no-sc: ## Closure Checks appended at end" "1" "$count"

    assert_pass_if_clean "test_no_success_criteria_gets_closure_checks_appended"
}
test_no_success_criteria_gets_closure_checks_appended

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: --dry-run flag prints output but makes no changes
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 9: --dry-run flag makes no actual changes"
test_dryrun_no_changes() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Record state before dry-run
    local edits1_before edits2_before
    edits1_before=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-01")
    edits2_before=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-02")

    local exit_code=0
    local output
    output=$(bash "$MIGRATE_SCRIPT" --target "$repo" --dry-run 2>/dev/null) || exit_code=$?

    # Must exit 0
    assert_eq "dry-run exits 0" "0" "$exit_code"

    # Must print DRY-RUN output
    assert_contains "dry-run: prints DRY-RUN output" "DRY-RUN" "$output"

    # No EDIT event files must have been created
    local edits1_after edits2_after
    edits1_after=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-01")
    edits2_after=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-02")
    assert_eq "dry-run: no EDIT events on epic-no-closure-01" "$edits1_before" "$edits1_after"
    assert_eq "dry-run: no EDIT events on epic-no-closure-02" "$edits2_before" "$edits2_after"

    # A subsequent normal run must still perform the migration
    local exit2=0
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit2=$?
    assert_eq "dry-run: subsequent normal run exits 0" "0" "$exit2"

    local desc1
    desc1=$(_get_ticket_description "$repo" "epic-no-closure-01")
    local count1
    count1=$(_count_closure_checks_sections "$desc1")
    assert_eq "dry-run: subsequent normal run migrates epic-no-closure-01" "1" "$count1"

    assert_pass_if_clean "test_dryrun_no_changes"
}
test_dryrun_no_changes

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: Creates a per-session progress file for resume semantics
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 10: creates a per-session progress file for resume tracking"
test_creates_progress_file() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Capture output to find the progress file path
    local output
    output=$(bash "$MIGRATE_SCRIPT" --target "$repo" 2>&1) || true

    # The script should emit the progress file path in its output
    # OR we can verify a progress file exists in /tmp with migrate-closure-checks prefix
    local progress_file_found=0
    # Check if any progress file was created with expected prefix pattern
    if ls /tmp/migrate-closure-checks.* >/dev/null 2>&1; then
        progress_file_found=1
    elif echo "$output" | grep -q "progress\|session\|resume"; then
        progress_file_found=1
    fi

    assert_eq "creates progress file or emits resume info" "1" "$progress_file_found"

    assert_pass_if_clean "test_creates_progress_file"
}
test_creates_progress_file

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: Processes in batches of ≤25 — large fixture completes successfully
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 11: processes 30 tickets (>1 batch of 25) successfully"
test_large_fixture_processes_in_batches() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_large_fixture "$repo/.tickets-tracker" 30

    local exit_code=0
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    assert_eq "large fixture (30 tickets): exits 0" "0" "$exit_code"

    # Spot check: first and last batch tickets got migrated
    local desc_first
    desc_first=$(_get_ticket_description "$repo" "epic-batch-test-001")
    local count_first
    count_first=$(_count_closure_checks_sections "$desc_first")
    assert_eq "batch-test-001: migrated" "1" "$count_first"

    local desc_last
    desc_last=$(_get_ticket_description "$repo" "epic-batch-test-030")
    local count_last
    count_last=$(_count_closure_checks_sections "$desc_last")
    assert_eq "batch-test-030 (batch 2): migrated" "1" "$count_last"

    assert_pass_if_clean "test_large_fixture_processes_in_batches"
}
test_large_fixture_processes_in_batches

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: Reads ticket IDs from stdin when piped
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 12: reads ticket IDs from stdin (pipe mode)"
test_reads_ticket_ids_from_stdin() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Pipe only epic-no-closure-01 — epic-no-closure-02 should NOT be processed
    local exit_code=0
    printf 'epic-no-closure-01\t epic\topen\tEpic lacking Closure Checks (1)\n' | \
        bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    # Should succeed
    assert_ne "stdin mode: exits without fatal error" "2" "$exit_code"

    # epic-no-closure-01 should be migrated
    local desc1
    desc1=$(_get_ticket_description "$repo" "epic-no-closure-01")
    local count1
    count1=$(_count_closure_checks_sections "$desc1")
    assert_eq "stdin mode: epic-no-closure-01 migrated" "1" "$count1"

    # epic-no-closure-02 should NOT be migrated (not in stdin list)
    local desc2
    desc2=$(_get_ticket_description "$repo" "epic-no-closure-02")
    local count2
    count2=$(_count_closure_checks_sections "$desc2")
    assert_eq "stdin mode: epic-no-closure-02 NOT migrated (not in list)" "0" "$count2"

    assert_pass_if_clean "test_reads_ticket_ids_from_stdin"
}
test_reads_ticket_ids_from_stdin

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: Exit 2 when .tickets-tracker is missing
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 13: exits 2 when .tickets-tracker is missing"
test_exits_2_when_tracker_missing() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-no-tracker.XXXXXX")
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
    bash "$MIGRATE_SCRIPT" --target "$tmp/bare-repo" >/dev/null 2>&1 || exit_code=$?

    assert_eq "exits 2 when .tickets-tracker absent" "2" "$exit_code"

    assert_pass_if_clean "test_exits_2_when_tracker_missing"
}
test_exits_2_when_tracker_missing

# ═══════════════════════════════════════════════════════════════════════════════
# Test 14: After migration, audit-closure-checks-migration.sh reports 0 tickets remaining
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 14: after migration, audit script reports 0 tickets remaining (exits 1)"
test_audit_reports_zero_after_migration() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local audit_script="$REPO_ROOT/plugins/dso/scripts/audit-closure-checks-migration.sh"
    if [ ! -f "$audit_script" ]; then
        # Audit script not present — skip this test
        echo "SKIP: audit-closure-checks-migration.sh not present, skipping test 14"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Run migration
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # Run audit — should exit 1 (all migrated = no remaining tickets)
    local audit_exit=0
    bash "$audit_script" --target "$repo" >/dev/null 2>&1 || audit_exit=$?

    assert_eq "audit exits 1 after migration (0 tickets remaining)" "1" "$audit_exit"

    assert_pass_if_clean "test_audit_reports_zero_after_migration"
}
test_audit_reports_zero_after_migration

# ═══════════════════════════════════════════════════════════════════════════════
# Test 15: Resume-from-progress-file skips already-processed tickets
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 15: resume-from-progress-file skips already-processed tickets in a second run"
test_resume_skips_already_processed() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Compute the same _TARGET_HASH that the script uses internally
    local target_hash
    target_hash=$(printf '%s' "$repo" | python3 -c "import sys, hashlib; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])")
    local progress_file="/tmp/migrate-closure-checks.${target_hash}.progress"
    _CLEANUP_DIRS+=("$progress_file")

    # Seed the progress file with epic-no-closure-01 as if it was already processed
    echo "epic-no-closure-01" > "$progress_file"

    # Run migration — epic-no-closure-01 should be skipped (in progress file)
    local output
    output=$(bash "$MIGRATE_SCRIPT" --target "$repo" 2>/dev/null)

    # epic-no-closure-01 should NOT have a new EDIT event (it was in progress file)
    local edit_count_01
    edit_count_01=$(_count_edit_events "$repo/.tickets-tracker" "epic-no-closure-01")
    assert_eq "resume: epic-no-closure-01 skipped (no new EDIT)" "0" "$edit_count_01"

    # epic-no-closure-02 should be migrated (not in progress file)
    local desc2
    desc2=$(_get_ticket_description "$repo" "epic-no-closure-02")
    local count2
    count2=$(_count_closure_checks_sections "$desc2")
    assert_eq "resume: epic-no-closure-02 migrated (not in progress file)" "1" "$count2"

    # Output should contain RESUME-SKIP for epic-no-closure-01
    local resume_skip_count
    resume_skip_count=$(echo "$output" | grep -c "RESUME-SKIP:.*epic-no-closure-01" 2>/dev/null || true)
    assert_eq "resume: RESUME-SKIP line emitted for already-processed ticket" "1" "$resume_skip_count"

    # Clean up progress file
    rm -f "$progress_file"

    assert_pass_if_clean "test_resume_skips_already_processed"
}
test_resume_skips_already_processed

# ═══════════════════════════════════════════════════════════════════════════════
# Test 16: Post-migration tickets satisfy completion-verifier Step 2.5 logic
# (structural proxy: verifier reads ## Closure Checks from compiled description)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 16: post-migration tickets pass completion-verifier Step 2.5 structural check"
test_post_migration_passes_verifier_step2_5() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_mixed_fixture "$repo/.tickets-tracker"

    # Run migration
    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # Structural proxy for completion-verifier Step 2.5:
    # The verifier reads ## Closure Checks from the compiled ticket description.
    # After migration, every epic/story that lacked the section should now have it.
    # Verify for each ticket that was missing the section (the three in the fixture).
    local all_pass=1
    for ticket_id in epic-no-closure-01 epic-no-closure-02 story-no-closure-01; do
        local desc
        desc=$(_get_ticket_description "$repo" "$ticket_id")
        # Replicate verifier Step 2.5: find "## Closure Checks" heading in description
        local verifier_result
        verifier_result=$(python3 -c "
import sys
desc = sys.argv[1]
CLOSURE_HEADING = '## Closure Checks'
found = CLOSURE_HEADING in desc
print('PASS' if found else 'FAIL')
" "$desc" 2>/dev/null || echo "FAIL")
        assert_eq "verifier Step 2.5 passes for $ticket_id post-migration" "PASS" "$verifier_result"
        [ "$verifier_result" != "PASS" ] && all_pass=0
    done

    # Also verify the already-migrated ticket was not double-migrated (verifier sees exactly 1 section)
    local desc_has
    desc_has=$(_get_ticket_description "$repo" "epic-has-closure-01")
    local section_count
    section_count=$(_count_closure_checks_sections "$desc_has")
    assert_eq "verifier Step 2.5: already-migrated ticket has exactly 1 section (no double-migration)" "1" "$section_count"

    assert_pass_if_clean "test_post_migration_passes_verifier_step2_5"
}
test_post_migration_passes_verifier_step2_5

# ═══════════════════════════════════════════════════════════════════════════════
# Test 17: Satisfies annotations pointing to Closure Checks text are rewritten
# Testing Mode: RED — requires annotation-rewrite step in migrate-closure-checks.sh
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 17: satisfies annotation rewritten to validates-closure-check"
test_satisfies_annotation_rewritten_to_validates_closure_check() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Parent epic: ALREADY has BOTH ## Success Criteria AND ## Closure Checks
    # (idempotent for the main migration; annotation-rewrite should still run)
    local epic_dir="$tracker_dir/epic-annotate-01"
    mkdir -p "$epic_dir"
    local epic_desc
    epic_desc='{"ticket_type": "epic", "title": "Epic with both SC and CC sections", "status": "open", "parent_id": null, "description": "## Context\n\nContext here.\n\n## Success Criteria\n- criterion X\n\n## Closure Checks\n- criterion X\n\n## Dependencies\nNone"}'
    _write_event "$epic_dir" "1742700100" "00000000-0000-4000-8000-annotate01001" "CREATE" "$epic_desc"

    # Child story: has annotation pointing to "criterion X" (which is in Closure Checks)
    local story_dir="$tracker_dir/story-annotate-01"
    mkdir -p "$story_dir"
    local story_desc
    story_desc='{"ticket_type": "story", "title": "Child story with Satisfies annotation", "status": "open", "parent_id": "epic-annotate-01", "description": "## Description\n\nAs a user, I want something.\n\n← Satisfies: \"criterion X\"\n\n## Done Definitions\n- DD1\n"}'
    _write_event "$story_dir" "1742700200" "00000000-0000-4000-8000-annotate01002" "CREATE" "$story_desc"

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # The child story annotation should be rewritten
    local story_desc_after
    story_desc_after=$(_get_ticket_description "$repo" "story-annotate-01")

    local has_old_annotation
    has_old_annotation=$(echo "$story_desc_after" | grep -c '← Satisfies:' 2>/dev/null || true)
    local has_new_annotation
    has_new_annotation=$(echo "$story_desc_after" | grep -c '← Validates Closure Check:' 2>/dev/null || true)

    assert_eq "story-annotate-01: old '← Satisfies:' annotation removed" "0" "$has_old_annotation"
    assert_eq "story-annotate-01: new '← Validates Closure Check:' annotation present" "1" "$has_new_annotation"

    assert_pass_if_clean "test_satisfies_annotation_rewritten_to_validates_closure_check"
}
test_satisfies_annotation_rewritten_to_validates_closure_check

# ═══════════════════════════════════════════════════════════════════════════════
# Test 18: Satisfies annotations pointing to SC-only text are NOT rewritten
# Testing Mode: RED — requires annotation-rewrite step in migrate-closure-checks.sh
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 18: satisfies annotation pointing to SC-only text remains unchanged"
test_satisfies_annotation_in_sc_unchanged() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Parent epic: "criterion Y" is ONLY in ## Success Criteria, NOT in Closure Checks
    local epic_dir="$tracker_dir/epic-annotate-02"
    mkdir -p "$epic_dir"
    local epic_desc
    epic_desc='{"ticket_type": "epic", "title": "Epic with SC-only criterion", "status": "open", "parent_id": null, "description": "## Context\n\nContext here.\n\n## Success Criteria\n- criterion Y\n\n## Dependencies\nNone"}'
    _write_event "$epic_dir" "1742700300" "00000000-0000-4000-8000-annotate02001" "CREATE" "$epic_desc"

    # Child story: has annotation pointing to "criterion Y" (which is only in SC)
    local story_dir="$tracker_dir/story-annotate-02"
    mkdir -p "$story_dir"
    local story_desc
    story_desc='{"ticket_type": "story", "title": "Child story with SC-only annotation", "status": "open", "parent_id": "epic-annotate-02", "description": "## Description\n\nAs a user, I want something.\n\n← Satisfies: \"criterion Y\"\n\n## Done Definitions\n- DD1\n"}'
    _write_event "$story_dir" "1742700400" "00000000-0000-4000-8000-annotate02002" "CREATE" "$story_desc"

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # The child story annotation for SC-only text should remain unchanged
    local story_desc_after
    story_desc_after=$(_get_ticket_description "$repo" "story-annotate-02")

    local has_old_annotation
    has_old_annotation=$(echo "$story_desc_after" | grep -c '← Satisfies:' 2>/dev/null || true)
    local has_new_annotation
    has_new_annotation=$(echo "$story_desc_after" | grep -c '← Validates Closure Check:' 2>/dev/null || true)

    assert_eq "story-annotate-02: '← Satisfies:' annotation preserved (SC-only text)" "1" "$has_old_annotation"
    assert_eq "story-annotate-02: no '← Validates Closure Check:' annotation added" "0" "$has_new_annotation"

    assert_pass_if_clean "test_satisfies_annotation_in_sc_unchanged"
}
test_satisfies_annotation_in_sc_unchanged

# ═══════════════════════════════════════════════════════════════════════════════
# Test 19: Zero orphaned annotations after migration
# Testing Mode: RED — requires annotation-rewrite step in migrate-closure-checks.sh
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 19: zero orphaned satisfies annotations after migration"
test_zero_orphaned_annotations_after_migration() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Parent epic: has BOTH SC and Closure Checks with overlapping content
    local epic_dir="$tracker_dir/epic-annotate-03"
    mkdir -p "$epic_dir"
    local epic_desc
    epic_desc='{"ticket_type": "epic", "title": "Epic with mixed SC and CC", "status": "open", "parent_id": null, "description": "## Context\n\nContext here.\n\n## Success Criteria\n- sc-only item\n- shared item\n\n## Closure Checks\n- shared item\n- cc-only item\n\n## Dependencies\nNone"}'
    _write_event "$epic_dir" "1742700500" "00000000-0000-4000-8000-annotate03001" "CREATE" "$epic_desc"

    # Child story 1: annotation pointing to Closure Checks text ("cc-only item")
    local story_dir1="$tracker_dir/story-annotate-03a"
    mkdir -p "$story_dir1"
    local story_desc1
    story_desc1='{"ticket_type": "story", "title": "Story with CC annotation", "status": "open", "parent_id": "epic-annotate-03", "description": "## Description\n\nAs a user, I want something.\n\n← Satisfies: \"cc-only item\"\n\n## Done Definitions\n- DD1\n"}'
    _write_event "$story_dir1" "1742700600" "00000000-0000-4000-8000-annotate03002" "CREATE" "$story_desc1"

    # Child story 2: annotation pointing to SC-only text ("sc-only item") — should NOT be rewritten
    local story_dir2="$tracker_dir/story-annotate-03b"
    mkdir -p "$story_dir2"
    local story_desc2
    story_desc2='{"ticket_type": "story", "title": "Story with SC-only annotation", "status": "open", "parent_id": "epic-annotate-03", "description": "## Description\n\nAs a user, I want something else.\n\n← Satisfies: \"sc-only item\"\n\n## Done Definitions\n- DD2\n"}'
    _write_event "$story_dir2" "1742700700" "00000000-0000-4000-8000-annotate03003" "CREATE" "$story_desc2"

    bash "$MIGRATE_SCRIPT" --target "$repo" >/dev/null 2>&1 || true

    # Get the Closure Checks items from the epic
    local epic_desc_after
    epic_desc_after=$(_get_ticket_description "$repo" "epic-annotate-03")

    # Extract the Closure Checks items
    local cc_items
    cc_items=$(python3 -c "
import re, sys
desc = sys.argv[1]
m = re.search(r'## Closure Checks\n(.*?)(?=\n## |\Z)', desc, re.DOTALL)
if not m:
    sys.exit(0)
section = m.group(1)
items = []
for line in section.splitlines():
    stripped = line.lstrip('-*+ \t').strip()
    if stripped:
        items.append(stripped)
print('\n'.join(items))
" "$epic_desc_after" 2>/dev/null || echo "")

    # For each child story, check that no '← Satisfies:' annotation points to a CC item
    local orphaned_count=0
    for story_id in story-annotate-03a story-annotate-03b; do
        local child_desc
        child_desc=$(_get_ticket_description "$repo" "$story_id")

        local story_orphans
        story_orphans=$(python3 -c "
import re, sys
desc = sys.argv[1]
cc_items_raw = sys.argv[2]
cc_items = [item.lower() for item in cc_items_raw.splitlines() if item.strip()]
# Find all '← Satisfies: \"text\"' annotations
matches = re.findall(r'← Satisfies:\s*\"([^\"]+)\"', desc)
orphans = sum(1 for m in matches if m.lower() in cc_items)
print(orphans)
" "$child_desc" "$cc_items" 2>/dev/null || echo "0")

        orphaned_count=$(( orphaned_count + story_orphans ))
    done

    assert_eq "zero orphaned '← Satisfies:' annotations pointing to Closure Checks text" "0" "$orphaned_count"

    assert_pass_if_clean "test_zero_orphaned_annotations_after_migration"
}
test_zero_orphaned_annotations_after_migration

# ── Helper: install a stub classifier and restore the real one on return ──────
# Usage: _with_stub_classifier <stub_path> <body>
# Sets _CLASSIFIER_STUB_INSTALLED=1 and stashes _CLASSIFIER_REAL_BACKUP path.
# Caller MUST call _restore_real_classifier after the run.
_CLASSIFIER_REAL_BACKUP=""
_install_stub_classifier() {
    local stub_src="$1"
    local script_dir
    script_dir="$(dirname "$MIGRATE_SCRIPT")"
    local real="$script_dir/closure-checks-classifier-pass.sh"
    _CLASSIFIER_REAL_BACKUP="$(mktemp "${TMPDIR:-/tmp}/real-classifier-backup.XXXXXX")"
    cp "$real" "$_CLASSIFIER_REAL_BACKUP"
    cp "$stub_src" "$real"
    chmod +x "$real"
}
_restore_real_classifier() {
    local script_dir
    script_dir="$(dirname "$MIGRATE_SCRIPT")"
    local real="$script_dir/closure-checks-classifier-pass.sh"
    if [ -n "$_CLASSIFIER_REAL_BACKUP" ] && [ -f "$_CLASSIFIER_REAL_BACKUP" ]; then
        cp "$_CLASSIFIER_REAL_BACKUP" "$real"
        rm -f "$_CLASSIFIER_REAL_BACKUP"
        _CLASSIFIER_REAL_BACKUP=""
    fi
}

# ── Helper: make a fast stub classifier ──────────────────────────────────────
_make_stub_classifier() {
    local stub
    stub=$(mktemp "${TMPDIR:-/tmp}/stub-classifier.XXXXXX")
    cat > "$stub" << 'STUB_EOF'
#!/usr/bin/env bash
# Test stub: fast no-op classifier; emits required BUDGET_CONSUMED line
echo "BUDGET_CONSUMED: 0"
exit 0
STUB_EOF
    chmod +x "$stub"
    echo "$stub"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 20: --classify mode epic-count cap truncates to DSO_CLASSIFY_MAX_EPICS
# Regression test for bug 2ac9-fabe-bbb9-4af2: unbounded --classify loop causes SIGKILL
# Uses stdin-pipe mode so the test repo's ticket-list CLI is not required.
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 20: --classify epic-count cap truncates when epics exceed DSO_CLASSIFY_MAX_EPICS"
test_classify_epic_count_cap() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Create 5 epic ticket dirs so the script can process them
    local i dir ts uuid desc
    for i in 1 2 3 4 5; do
        dir="$tracker_dir/epic-cap-test-$(printf '%02d' "$i")"
        mkdir -p "$dir"
        ts=$(( 1742800000 + i ))
        uuid="00000000-0000-4000-8000-cap$(printf '%06d' "$i")"
        desc="{\"ticket_type\": \"epic\", \"title\": \"Cap test epic $i\", \"status\": \"open\", \"parent_id\": null, \"description\": \"## Context\\n\\nEpic $i context.\\n\\n## Success Criteria\\n- SC$i\\n## Closure Checks\\n\"}"
        _write_event "$dir" "$ts" "$uuid" "CREATE" "$desc"
        git -C "$tracker_dir" add "epic-cap-test-$(printf '%02d' "$i")" 2>/dev/null
    done
    git -C "$tracker_dir" commit -m "add cap test epics" >/dev/null 2>&1 || true

    # Install stub classifier (replaces real classifier temporarily)
    local stub
    stub=$(_make_stub_classifier)
    _CLEANUP_DIRS+=("$stub")
    _install_stub_classifier "$stub"

    # Pipe 5 lines via stdin — cap (3) < input (5), so 2 should be deferred
    local fake_lines=""
    for i in 1 2 3 4 5; do
        fake_lines="${fake_lines}epic-cap-test-$(printf '%02d' "$i")\tepic\topen\tCap test epic $i\n"
    done

    local output
    local exit_code=0
    output=$(printf '%b' "$fake_lines" | DSO_CLASSIFY_MAX_EPICS=3 bash "$MIGRATE_SCRIPT" --target "$repo" --classify 2>&1) || exit_code=$?

    _restore_real_classifier

    # Should not exit with fatal error (2)
    assert_ne "classify cap: no fatal exit (exit != 2)" "2" "$exit_code"

    # Output must mention the cap being reached and deferred count
    local cap_line_count
    cap_line_count=$(echo "$output" | grep -c "Epic-count cap reached" 2>/dev/null || true)
    assert_eq "classify cap: emits 'Epic-count cap reached' message" "1" "$cap_line_count"

    # Output must mention that 2 epics were deferred (5 total - 3 cap = 2)
    local deferred_count
    deferred_count=$(echo "$output" | grep "Epic-count cap reached" | grep -c "2 deferred" 2>/dev/null || true)
    assert_eq "classify cap: message includes deferred count (2)" "1" "$deferred_count"

    assert_pass_if_clean "test_classify_epic_count_cap"
}
test_classify_epic_count_cap

# ═══════════════════════════════════════════════════════════════════════════════
# Test 21: --classify mode wall-time guard breaks cleanly when limit exceeded
# Regression test for bug 2ac9-fabe-bbb9-4af2: unbounded --classify loop causes SIGKILL
# Uses stdin-pipe mode; sets DSO_CLASSIFY_WALL_TIME_SECS=0 so guard fires immediately.
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 21: --classify wall-time guard breaks cleanly on timeout"
test_classify_wall_time_guard() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migrate script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Create 3 epic ticket dirs with Closure Checks already present (SKIPPED state)
    # so the classifier path is exercised and the wall-time guard can fire
    local i dir ts uuid desc
    for i in 1 2 3; do
        dir="$tracker_dir/epic-wall-test-$(printf '%02d' "$i")"
        mkdir -p "$dir"
        ts=$(( 1742900000 + i ))
        uuid="00000000-0000-4000-8000-wall$(printf '%06d' "$i")"
        desc="{\"ticket_type\": \"epic\", \"title\": \"Wall test epic $i\", \"status\": \"open\", \"parent_id\": null, \"description\": \"## Context\\n\\nEpic $i.\\n\\n## Closure Checks\\n\"}"
        _write_event "$dir" "$ts" "$uuid" "CREATE" "$desc"
        git -C "$tracker_dir" add "epic-wall-test-$(printf '%02d' "$i")" 2>/dev/null
    done
    git -C "$tracker_dir" commit -m "add wall test epics" >/dev/null 2>&1 || true

    # Install stub classifier
    local stub
    stub=$(_make_stub_classifier)
    _CLEANUP_DIRS+=("$stub")
    _install_stub_classifier "$stub"

    # Pipe 3 lines via stdin; wall-time=0 so the guard fires before/during first epic
    local fake_lines=""
    for i in 1 2 3; do
        fake_lines="${fake_lines}epic-wall-test-$(printf '%02d' "$i")\tepic\topen\tWall test epic $i\n"
    done

    local output
    local exit_code=0
    output=$(printf '%b' "$fake_lines" | DSO_CLASSIFY_MAX_EPICS=100 DSO_CLASSIFY_WALL_TIME_SECS=0 bash "$MIGRATE_SCRIPT" --target "$repo" --classify 2>&1) || exit_code=$?

    _restore_real_classifier

    # Should not exit with fatal error (2)
    assert_ne "wall-time guard: no fatal exit (exit != 2)" "2" "$exit_code"

    # Output must contain WALL_TIME_EXCEEDED
    local wt_line_count
    wt_line_count=$(echo "$output" | grep -c "WALL_TIME_EXCEEDED" 2>/dev/null || true)
    assert_eq "wall-time guard: emits WALL_TIME_EXCEEDED message" "1" "$wt_line_count"

    # The summary line (Migration complete) must still appear (clean break)
    local summary_count
    summary_count=$(echo "$output" | grep -c "Migration complete" 2>/dev/null || true)
    assert_eq "wall-time guard: summary still printed (clean break)" "1" "$summary_count"

    assert_pass_if_clean "test_classify_wall_time_guard"
}
test_classify_wall_time_guard

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
