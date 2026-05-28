#!/usr/bin/env bash
# tests/scripts/test-coherence-walk.sh
# Behavioral fixture test for plugins/dso/scripts/coherence-walk.sh
#
#
# Test structure:
#   - Fixtures with epics/stories that have clean SC sections (PASS)
#   - Fixtures with transitional language in SC (AMBIGUOUS)
#   - Fixtures with SC items that duplicate ## Closure Checks text (FAIL)
#   - Fixtures with missing sections (PASS — backward-compat)
#
# Assertions:
#   1. Script exists and is executable
#   2. Accepts --target flag
#   3. Emits PASS/FAIL/AMBIGUOUS lines with ticket-id and reason
#   4. Exits 0 when all tickets PASS
#   5. Exits non-zero when any ticket FAILs
#   6. Output includes COHERENCE_SUMMARY line
#   7. COHERENCE_SUMMARY format: COHERENCE_SUMMARY: N_pass=X N_fail=Y N_ambiguous=Z
#   8. AMBIGUOUS emitted for transitional language (currently/temporary/TODO/pending/until)
#   9. FAIL emitted when SC text duplicates Closure Checks text
#  10. PASS when no ## Success Criteria section (backward-compat)
#  11. Recommended next step in output for FAIL/AMBIGUOUS tickets
#  12. Handles missing .tickets-tracker gracefully (exits 2 with error)
#
# Usage: bash tests/scripts/test-coherence-walk.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
COHERENCE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/coherence-walk.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-coherence-walk.sh ==="

# ── Suite-runner guard: skip when script does not exist ──────────────────────
# RED tests fail by design (script not found). When auto-discovered by
# run-script-tests.sh, they would break `bash tests/run-all.sh`. Skip with
# exit 0 when coherence-walk.sh is absent AND running under the suite runner.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$COHERENCE_SCRIPT" ]; then
    echo "SKIP: coherence-walk.sh not yet implemented (RED) — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh temp repo ─────────────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-coherence-walk.XXXXXX")
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

# ── Fixture: all-pass — clean SC sections, no issues ─────────────────────────
_setup_all_pass_fixture() {
    local tracker_dir="$1"

    # Epic with clean SC and Closure Checks (no overlap)
    local dir1="$tracker_dir/epic-clean-sc"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic with clean SC", "status": "open", "parent_id": null, "description": "## Success Criteria\n- Users can export data\n- All exports are audited\n\n## Closure Checks\n- Export log is durable\n- Audit trail persists"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-coh001001" "CREATE" "$desc1"

    # Story with no SC section (backward-compat PASS)
    local dir2="$tracker_dir/story-no-sc"
    mkdir -p "$dir2"
    local desc2
    desc2='{"ticket_type": "story", "title": "Story with no SC section", "status": "open", "parent_id": "epic-clean-sc", "description": "## Description\n\nSome description.\n\n## Done Definitions\n- When complete, user sees results\n"}'
    _write_event "$dir2" "1742605200" "00000000-0000-4000-8000-coh002001" "CREATE" "$desc2"
}

# ── Fixture: transitional language — triggers AMBIGUOUS ──────────────────────
_setup_ambiguous_fixture() {
    local tracker_dir="$1"

    # Epic with "currently" in SC
    local dir1="$tracker_dir/epic-transitional-currently"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic with currently language", "status": "open", "parent_id": null, "description": "## Success Criteria\n- The system currently supports 3 export formats\n- All exports are audited\n\n## Closure Checks\n- Export log is durable"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-coh101001" "CREATE" "$desc1"

    # Story with "temporary" in SC
    local dir2="$tracker_dir/story-transitional-temporary"
    mkdir -p "$dir2"
    local desc2
    desc2='{"ticket_type": "story", "title": "Story with temporary language", "status": "open", "parent_id": "epic-transitional-currently", "description": "## Success Criteria\n- Use temporary workaround for auth\n\n## Closure Checks\n- Auth is stable"}'
    _write_event "$dir2" "1742605200" "00000000-0000-4000-8000-coh102001" "CREATE" "$desc2"

    # Epic with "TODO" in SC
    local dir3="$tracker_dir/epic-transitional-todo"
    mkdir -p "$dir3"
    local desc3
    desc3='{"ticket_type": "epic", "title": "Epic with TODO language", "status": "open", "parent_id": null, "description": "## Success Criteria\n- TODO: define acceptance criteria\n- All exports audited\n\n## Closure Checks\n- Audit trail persists"}'
    _write_event "$dir3" "1742605300" "00000000-0000-4000-8000-coh103001" "CREATE" "$desc3"
}

# ── Fixture: duplicate SC/Closure Checks text — triggers FAIL ───────────────
_setup_fail_fixture() {
    local tracker_dir="$1"

    # Epic where SC text duplicates Closure Checks text
    local dir1="$tracker_dir/epic-sc-dup-closure"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic with SC duplicating closure", "status": "open", "parent_id": null, "description": "## Success Criteria\n- Export log is durable\n- Audit trail persists\n\n## Closure Checks\n- Export log is durable\n- Audit trail persists"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-coh201001" "CREATE" "$desc1"
}

# ── Fixture: mixed — some pass, some ambiguous, some fail ────────────────────
_setup_mixed_fixture() {
    local tracker_dir="$1"
    _setup_all_pass_fixture "$tracker_dir"
    _setup_ambiguous_fixture "$tracker_dir"
    _setup_fail_fixture "$tracker_dir"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable (RED gate)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: coherence-walk script exists and is executable"
test_script_exists_and_executable() {
    _snapshot_fail
    if [ -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists" "exists" "exists"
    else
        assert_eq "coherence-walk.sh exists" "exists" "missing"
    fi
    if [ -x "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh is executable" "executable" "executable"
    else
        assert_eq "coherence-walk.sh is executable" "executable" "not-executable"
    fi
    assert_pass_if_clean "test_script_exists_and_executable"
}
test_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: Accepts --target flag without error
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: accepts --target flag"
test_accepts_target_flag() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_accepts_target_flag"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_all_pass_fixture "$repo/.tickets-tracker"

    local exit_code=0
    bash "$COHERENCE_SCRIPT" --target "$repo" >/dev/null 2>&1 || exit_code=$?

    # Exit codes 0 (all pass) or 1 (some fail) are acceptable; 2 means error
    assert_ne "exit code is not error (2)" "2" "$exit_code"

    assert_pass_if_clean "test_accepts_target_flag"
}
test_accepts_target_flag

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Output includes PASS lines for clean tickets
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: emits PASS lines for clean tickets"
test_emits_pass_lines() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_emits_pass_lines"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_all_pass_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_contains "output contains PASS" "PASS" "$output"

    assert_pass_if_clean "test_emits_pass_lines"
}
test_emits_pass_lines

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Exits 0 when all tickets PASS
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: exits 0 when all tickets PASS"
test_exits_0_all_pass() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_exits_0_all_pass"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_all_pass_fixture "$repo/.tickets-tracker"

    local exit_code=0
    bash "$COHERENCE_SCRIPT" --target "$repo" >/dev/null 2>/dev/null || exit_code=$?

    assert_eq "exit code is 0 when all pass" "0" "$exit_code"

    assert_pass_if_clean "test_exits_0_all_pass"
}
test_exits_0_all_pass

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: Exits non-zero when any ticket FAILs
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: exits non-zero when any ticket FAILs"
test_exits_nonzero_on_fail() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_exits_nonzero_on_fail"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_fail_fixture "$repo/.tickets-tracker"

    local exit_code=0
    bash "$COHERENCE_SCRIPT" --target "$repo" >/dev/null 2>/dev/null || exit_code=$?

    assert_ne "exit code is not 0 when FAIL present" "0" "$exit_code"

    assert_pass_if_clean "test_exits_nonzero_on_fail"
}
test_exits_nonzero_on_fail

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: Output includes COHERENCE_SUMMARY line
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: output includes COHERENCE_SUMMARY line"
test_emits_coherence_summary() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_emits_coherence_summary"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_all_pass_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_contains "output contains COHERENCE_SUMMARY" "COHERENCE_SUMMARY:" "$output"

    assert_pass_if_clean "test_emits_coherence_summary"
}
test_emits_coherence_summary

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: COHERENCE_SUMMARY has correct format (N_pass= N_fail= N_ambiguous=)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: COHERENCE_SUMMARY line has correct format"
test_coherence_summary_format() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_coherence_summary_format"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_all_pass_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_contains "COHERENCE_SUMMARY contains N_pass=" "N_pass=" "$output"
    assert_contains "COHERENCE_SUMMARY contains N_fail=" "N_fail=" "$output"
    assert_contains "COHERENCE_SUMMARY contains N_ambiguous=" "N_ambiguous=" "$output"

    assert_pass_if_clean "test_coherence_summary_format"
}
test_coherence_summary_format

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: AMBIGUOUS emitted for transitional language
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: AMBIGUOUS emitted for transitional language in SC"
test_ambiguous_for_transitional_language() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_ambiguous_for_transitional_language"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_ambiguous_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_contains "output contains AMBIGUOUS" "AMBIGUOUS" "$output"
    assert_contains "output contains epic-transitional-currently" "epic-transitional-currently" "$output"

    assert_pass_if_clean "test_ambiguous_for_transitional_language"
}
test_ambiguous_for_transitional_language

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: FAIL emitted when SC text duplicates Closure Checks text
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 9: FAIL emitted for SC text that duplicates Closure Checks"
test_fail_for_duplicate_sc_closure() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_fail_for_duplicate_sc_closure"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_fail_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    assert_contains "output contains FAIL" "FAIL" "$output"
    assert_contains "output contains epic-sc-dup-closure" "epic-sc-dup-closure" "$output"

    assert_pass_if_clean "test_fail_for_duplicate_sc_closure"
}
test_fail_for_duplicate_sc_closure

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: PASS when no ## Success Criteria section (backward-compat)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 10: PASS when no ## Success Criteria section (backward-compat)"
test_pass_when_no_sc_section() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_pass_when_no_sc_section"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket with no SC section
    local tracker_dir="$repo/.tickets-tracker"
    local dir1="$tracker_dir/epic-no-sc"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic with no SC", "status": "open", "parent_id": null, "description": "## Context\n\nSome context here.\n\n## Closure Checks\n- Durable end-state item"}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-coh301001" "CREATE" "$desc1"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    # Should produce PASS for this ticket (no SC = no conflict)
    assert_contains "output contains PASS for epic-no-sc" "PASS" "$output"
    assert_not_contains "output does not contain FAIL for epic-no-sc" "FAIL" "$output"
    assert_not_contains "output does not contain AMBIGUOUS for epic-no-sc" "AMBIGUOUS" "$output"

    assert_pass_if_clean "test_pass_when_no_sc_section"
}
test_pass_when_no_sc_section

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: FAIL/AMBIGUOUS output includes recommended next step
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 11: FAIL/AMBIGUOUS output includes recommended next step"
test_fail_includes_next_step() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_fail_includes_next_step"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_fail_fixture "$repo/.tickets-tracker"

    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" 2>/dev/null) || true

    # FAIL/AMBIGUOUS output should include a recommended next step
    assert_contains "output contains NEXT_STEP or recommended action" "NEXT_STEP" "$output"

    assert_pass_if_clean "test_fail_includes_next_step"
}
test_fail_includes_next_step

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: Handles missing .tickets-tracker gracefully
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 12: handles missing .tickets-tracker gracefully"
test_handles_missing_tracker() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_handles_missing_tracker"
        return
    fi

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-coherence-walk-missing.XXXXXX")
    _CLEANUP_DIRS+=("$tmp")

    local exit_code=0
    bash "$COHERENCE_SCRIPT" --target "$tmp" 2>/dev/null || exit_code=$?

    assert_eq "exit code is 2 for missing .tickets-tracker" "2" "$exit_code"

    assert_pass_if_clean "test_handles_missing_tracker"
}
test_handles_missing_tracker

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: --epic filter restricts scan to specified epic only
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 13: --epic filter restricts scan to specified epic only"
test_epic_filter_restricts_scan() {
    _snapshot_fail

    if [ ! -f "$COHERENCE_SCRIPT" ]; then
        assert_eq "coherence-walk.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_epic_filter_restricts_scan"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create two epics: epic-A (clean), epic-B (transitional language → AMBIGUOUS)
    # Use \\n so printf produces literal \n (valid JSON escape) not actual newlines.
    local tracker="$repo/.tickets-tracker"
    mkdir -p "$tracker/epic-A" "$tracker/epic-B"
    printf '{"event_type":"CREATE","data":{"ticket_type":"epic","title":"Clean Epic","description":"## Success Criteria\\n- System is ready\\n"}}\n' \
        > "$tracker/epic-A/001-CREATE.json"
    printf '{"event_type":"CREATE","data":{"ticket_type":"epic","title":"Transitional Epic","description":"## Success Criteria\\n- Currently blocked by dependency X\\n"}}\n' \
        > "$tracker/epic-B/001-CREATE.json"

    # Filter to only epic-A — output should contain epic-A but NOT epic-B
    local output
    output=$(bash "$COHERENCE_SCRIPT" --target "$repo" --epic epic-A 2>/dev/null) || true

    local epic_a_present=0
    echo "$output" | grep -q "epic-A" && epic_a_present=1
    assert_eq "--epic filter includes target epic" "1" "$epic_a_present"

    local epic_b_present=0
    echo "$output" | grep -q "epic-B" && epic_b_present=1
    assert_eq "--epic filter excludes other epics" "0" "$epic_b_present"

    assert_pass_if_clean "test_epic_filter_restricts_scan"
}
test_epic_filter_restricts_scan

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
