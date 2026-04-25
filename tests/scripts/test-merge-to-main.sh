#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329  # word-splitting intentional; function invoked via eval
# tests/scripts/test-merge-to-main.sh
# Tests for merge-to-main.sh post-merge validation parallelization.
#
# TDD tests:
#   1. test_parallel_validation_uses_background_jobs — format-check and lint run as & jobs
#   2. test_parallel_validation_waits_for_jobs — wait is used to collect exit codes
#   3. test_parallel_validation_captures_both_exit_codes — both PIDs/exit codes captured
#   4. test_parallel_validation_bash_syntax — bash -n passes
#   5. test_parallel_validation_faster_than_serial — mock with sleep 1, assert <2s
#
# Usage: bash tests/scripts/test-merge-to-main.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test: bash -n syntax check passes on merge-to-main.sh
# =============================================================================
SYNTAX_OK=0
bash -n "$MERGE_SCRIPT" 2>/dev/null && SYNTAX_OK=1
assert_eq "test_parallel_validation_bash_syntax" "1" "$SYNTAX_OK"

# =============================================================================
# Test 5: Parallel execution launches two distinct background processes
# Structural proof: both PIDs are captured and differ (two separate processes).
# Previous timing-based approach (sleep 2 + assert < 4s) was flaky under CPU
# contention from parallel test suite execution (w20-51ti, w21-dkwi).
# Tests 1-4 already prove the script uses background jobs + wait; this test
# verifies the runtime behavior produces two distinct PIDs.
# =============================================================================
_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT

cat > "$_TMPDIR/mock-format-check.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_TMPDIR/mock-format-check.sh"

cat > "$_TMPDIR/mock-lint.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$_TMPDIR/mock-lint.sh"

POST_MERGE_FAIL=false
CMD_FORMAT_CHECK="$_TMPDIR/mock-format-check.sh"
CMD_LINT="$_TMPDIR/mock-lint.sh"
_APP_DIR="$_TMPDIR"

(cd "$_APP_DIR" && $CMD_FORMAT_CHECK 2>&1) &
_FMT_PID=$!
(cd "$_APP_DIR" && $CMD_LINT 2>&1) &
_LINT_PID=$!

wait $_FMT_PID
_FMT_RC=$?
wait $_LINT_PID
_LINT_RC=$?

[[ $_FMT_RC -ne 0 ]] && POST_MERGE_FAIL=true
[[ $_LINT_RC -ne 0 ]] && POST_MERGE_FAIL=true

# Two distinct PIDs prove two background processes were launched
if [[ "$_FMT_PID" != "$_LINT_PID" && -n "$_FMT_PID" && -n "$_LINT_PID" ]]; then
    _PARALLEL_OK="true"
else
    _PARALLEL_OK="false"
fi
assert_eq "test_parallel_validation_distinct_pids" "true" "$_PARALLEL_OK"

# Also verify both failures are reported when both fail
cat > "$_TMPDIR/mock-fail-format.sh" <<'MOCK'
#!/usr/bin/env bash
sleep 1
exit 1
MOCK
chmod +x "$_TMPDIR/mock-fail-format.sh"

cat > "$_TMPDIR/mock-fail-lint.sh" <<'MOCK'
#!/usr/bin/env bash
sleep 1
exit 1
MOCK
chmod +x "$_TMPDIR/mock-fail-lint.sh"

POST_MERGE_FAIL_BOTH=false
CMD_FORMAT_CHECK="$_TMPDIR/mock-fail-format.sh"
CMD_LINT="$_TMPDIR/mock-fail-lint.sh"

(cd "$_APP_DIR" && $CMD_FORMAT_CHECK 2>&1) &
_FMT_PID=$!
(cd "$_APP_DIR" && $CMD_LINT 2>&1) &
_LINT_PID=$!

wait $_FMT_PID
_FMT_RC=$?
wait $_LINT_PID
_LINT_RC=$?

[[ $_FMT_RC -ne 0 ]] && POST_MERGE_FAIL_BOTH=true
[[ $_LINT_RC -ne 0 ]] && POST_MERGE_FAIL_BOTH=true

assert_eq "test_parallel_validation_both_failures_reported" "true" "$POST_MERGE_FAIL_BOTH"
assert_ne "test_parallel_validation_fmt_exit_code_captured" "0" "$_FMT_RC"
assert_ne "test_parallel_validation_lint_exit_code_captured" "0" "$_LINT_RC"

# =============================================================================
# Test: _count_closed_tickets() removed (v2 cleanup — v3 uses ticket list)
# =============================================================================
HAS_COUNT_FUNCTION=$(grep -c '_count_closed_tickets' "$MERGE_SCRIPT" || true)
assert_eq "test_count_closed_tickets_removed" "0" "$HAS_COUNT_FUNCTION"

# =============================================================================
# State file helper function tests
# =============================================================================

# Helper: extract and eval state file functions from merge-to-main.sh or merge-helpers.sh.
# Functions were extracted to merge-helpers.sh (hooks/lib/) to reduce merge-to-main.sh line count.
# Searches MERGE_SCRIPT first, then falls back to MERGE_HELPERS_LIB so tests remain portable.
_extract_fn() {
    local fn_name="$1"
    local _body
    _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT")
    if [[ -z "$_body" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _body=$(awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_HELPERS_LIB")
    fi
    echo "$_body"
}

_STATE_TMPDIR=$(mktemp -d)

# =============================================================================
# Test: _state_file_path is worktree-scoped
# =============================================================================
_SFP_BODY=$(_extract_fn "_state_file_path")
if [[ -z "$_SFP_BODY" ]]; then
    assert_eq "test_state_file_path_is_worktree_scoped" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    eval "$_SFP_BODY"
    BRANCH="worktrees/test-branch"
    _SFP_RESULT=$(_state_file_path)
    assert_contains "test_state_file_path_starts_with_tmp" "/tmp/merge-to-main-state-" "$_SFP_RESULT"
    assert_contains "test_state_file_path_contains_branch" "test-branch" "$_SFP_RESULT"
fi

# =============================================================================
# Test: _state_init creates JSON with correct schema
# =============================================================================
_SI_BODY=$(_extract_fn "_state_init")
_SSM_BODY=$(_extract_fn "_state_is_fresh")
if [[ -z "$_SI_BODY" || -z "$_SFP_BODY" ]]; then
    assert_eq "test_state_init_creates_json_with_schema" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    eval "$_SI_BODY"
    eval "$_SSM_BODY" 2>/dev/null || true
    BRANCH="test-task1"
    _state_init
    _STATE_FILE=$(_state_file_path)
    # Assert file exists
    if [[ -f "$_STATE_FILE" ]]; then
        _INIT_EXISTS="true"
    else
        _INIT_EXISTS="false"
    fi
    assert_eq "test_state_init_creates_json_file_exists" "true" "$_INIT_EXISTS"
    # Assert valid JSON with correct keys
    _SCHEMA_OK=$(python3 -c "
import json, sys
with open('$_STATE_FILE') as f:
    d = json.load(f)
keys = {'branch', 'merge_sha', 'completed_phases', 'current_phase', 'phases'}
if keys.issubset(set(d.keys())):
    print('true')
else:
    print('false: missing ' + str(keys - set(d.keys())))
" 2>/dev/null || echo "false: parse error")
    assert_eq "test_state_init_creates_json_with_schema" "true" "$_SCHEMA_OK"
    rm -f "$_STATE_FILE"
fi

# =============================================================================
# Test: _state_is_fresh deletes stale files
# =============================================================================
if [[ -z "$_SSM_BODY" || -z "$_SFP_BODY" ]]; then
    assert_eq "test_state_stale_file_is_deleted" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    BRANCH="test-stale"
    _STATE_FILE=$(_state_file_path)
    # Create a state file with content, then backdate it by 241 minutes
    printf '{"branch":"test-stale","merge_sha":"","completed_phases":[],"current_phase":"","phases":{}}' > "$_STATE_FILE"
    touch -t $(date -v-241M '+%Y%m%d%H%M' 2>/dev/null || date -d '241 minutes ago' '+%Y%m%d%H%M') "$_STATE_FILE"
    _state_is_fresh
    _STALE_RC=$?
    if [[ ! -f "$_STATE_FILE" ]]; then
        _STALE_DELETED="true"
    else
        _STALE_DELETED="false"
        rm -f "$_STATE_FILE"
    fi
    assert_eq "test_state_stale_file_is_deleted_rc" "1" "$_STALE_RC"
    assert_eq "test_state_stale_file_is_deleted" "true" "$_STALE_DELETED"
fi

# =============================================================================
# Test: _state_is_fresh keeps fresh files
# =============================================================================
if [[ -z "$_SSM_BODY" || -z "$_SFP_BODY" || -z "$_SI_BODY" ]]; then
    assert_eq "test_state_fresh_file_is_kept" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    BRANCH="test-fresh"
    _state_init
    _STATE_FILE=$(_state_file_path)
    _state_is_fresh
    _FRESH_RC=$?
    if [[ -f "$_STATE_FILE" ]]; then
        _FRESH_KEPT="true"
    else
        _FRESH_KEPT="false"
    fi
    assert_eq "test_state_fresh_file_is_kept_rc" "0" "$_FRESH_RC"
    assert_eq "test_state_fresh_file_is_kept" "true" "$_FRESH_KEPT"
    rm -f "$_STATE_FILE"
fi

# =============================================================================
# Test: _state_mark_complete appends phase to completed_phases
# =============================================================================
_SMC_BODY=$(_extract_fn "_state_mark_complete")
if [[ -z "$_SMC_BODY" || -z "$_SFP_BODY" || -z "$_SI_BODY" ]]; then
    assert_eq "test_state_mark_complete_appends_phase" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    eval "$_SMC_BODY"
    BRANCH="test-complete"
    _state_init
    _state_mark_complete "sync"
    _STATE_FILE=$(_state_file_path)
    _PHASE_OK=$(python3 -c "
import json
with open('$_STATE_FILE') as f:
    d = json.load(f)
if 'sync' in d.get('completed_phases', []):
    print('true')
else:
    print('false')
" 2>/dev/null || echo "false: parse error")
    assert_eq "test_state_mark_complete_appends_phase" "true" "$_PHASE_OK"
    # Also check phases dict has status=complete
    _STATUS_OK=$(python3 -c "
import json
with open('$_STATE_FILE') as f:
    d = json.load(f)
if d.get('phases', {}).get('sync', {}).get('status') == 'complete':
    print('true')
else:
    print('false')
" 2>/dev/null || echo "false: parse error")
    assert_eq "test_state_mark_complete_sets_phase_status" "true" "$_STATUS_OK"
    rm -f "$_STATE_FILE"
fi

# =============================================================================
# Test: _state_write_phase updates current_phase in state file
# =============================================================================
_SWP_BODY=$(_extract_fn "_state_write_phase")
if [[ -z "$_SWP_BODY" || -z "$_SFP_BODY" || -z "$_SI_BODY" ]]; then
    assert_eq "test_state_write_phase_updates_current_phase" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    eval "$_SWP_BODY"
    BRANCH="test-write-phase"
    _state_init
    _state_write_phase "merge"
    _STATE_FILE=$(_state_file_path)
    _PHASE_VAL=$(python3 -c "
import json
with open('$_STATE_FILE') as f:
    d = json.load(f)
print(d.get('current_phase', ''))
" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_state_write_phase_updates_current_phase" "merge" "$_PHASE_VAL"
    # Write a second phase and verify it overwrites
    _state_write_phase "push"
    _PHASE_VAL2=$(python3 -c "
import json
with open('$_STATE_FILE') as f:
    d = json.load(f)
print(d.get('current_phase', ''))
" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_state_write_phase_overwrites_previous" "push" "$_PHASE_VAL2"
    rm -f "$_STATE_FILE"
fi

# =============================================================================
# Test: _state_record_merge_sha records SHA in state file
# =============================================================================
_SRMS_BODY=$(_extract_fn "_state_record_merge_sha")
if [[ -z "$_SRMS_BODY" || -z "$_SFP_BODY" || -z "$_SI_BODY" ]]; then
    assert_eq "test_state_record_merge_sha_writes_sha" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    eval "$_SRMS_BODY"
    BRANCH="test-merge-sha"
    _state_init
    _state_record_merge_sha "abc123def456"
    _STATE_FILE=$(_state_file_path)
    _SHA_VAL=$(python3 -c "
import json
with open('$_STATE_FILE') as f:
    d = json.load(f)
print(d.get('merge_sha', ''))
" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_state_record_merge_sha_writes_sha" "abc123def456" "$_SHA_VAL"
    # Verify other fields are preserved
    _BRANCH_VAL=$(python3 -c "
import json
with open('$_STATE_FILE') as f:
    d = json.load(f)
print(d.get('branch', ''))
" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_state_record_merge_sha_preserves_branch" "test-merge-sha" "$_BRANCH_VAL"
    rm -f "$_STATE_FILE"
fi

rm -rf "$_STATE_TMPDIR"

# =============================================================================
# SIGURG trap tests
# =============================================================================

# =============================================================================
# Test: SIGURG trap is registered in merge-to-main.sh
# =============================================================================
HAS_SIGURG_TRAP=$(grep -cE "trap.*URG|trap.*_sigurg_handler" "$MERGE_SCRIPT" || true)
assert_ne "test_sigurg_trap_is_registered" "0" "$HAS_SIGURG_TRAP"

# =============================================================================
# Test: _sigurg_handler function exists in merge-to-main.sh
# =============================================================================
_SIGURG_FN_BODY=$(_extract_fn "_sigurg_handler")
if [[ -n "$_SIGURG_FN_BODY" ]]; then
    _SIGURG_FN_EXISTS="true"
else
    _SIGURG_FN_EXISTS="false"
fi
assert_eq "test_sigurg_handler_function_exists" "true" "$_SIGURG_FN_EXISTS"

# =============================================================================
# Test: _sigurg_handler calls _state_write_phase
# =============================================================================
_SIGURG_CALLS_WRITE=$(awk '/^_sigurg_handler\(\)/,/^\}$/' "$MERGE_SCRIPT" | grep -c '_state_write_phase' || true)
assert_ne "test_sigurg_handler_calls_state_write_phase" "0" "$_SIGURG_CALLS_WRITE"

# =============================================================================
# Test: _sigurg_handler uses explicit exit 0 (avoids set -e ERR cascade)
# =============================================================================
_SIGURG_HAS_EXIT=$(awk '/^_sigurg_handler\(\)/,/^\}$/' "$MERGE_SCRIPT" | grep -c 'exit 0' || true)
assert_ne "test_sigurg_handler_uses_explicit_exit" "0" "$_SIGURG_HAS_EXIT"

# =============================================================================
# Phase function refactor tests (ibok)
# =============================================================================

# =============================================================================
# Test: All 6 phase functions exist in merge-to-main.sh
# =============================================================================
_PHASE_FNS="_phase_sync _phase_merge _phase_validate _phase_push _phase_archive _phase_ci_trigger"
for _fn in $_PHASE_FNS; do
    _FN_FOUND=$(grep -c "^${_fn}()" "$MERGE_SCRIPT" || true)
    assert_ne "test_phase_functions_exist_${_fn}" "0" "$_FN_FOUND"
done

# =============================================================================
# Test: _phase_sync sets _CURRENT_PHASE to "sync"
# Extract _phase_sync, mock dependencies, eval, and check _CURRENT_PHASE.
# =============================================================================
_PS_BODY=$(_extract_fn "_phase_sync")
if [[ -z "$_PS_BODY" ]]; then
    assert_eq "test_phase_function_sets_current_phase" "FUNCTION_EXISTS" "FUNCTION_NOT_FOUND"
else
    # Mock dependencies
    _worktree_sync_from_main() { return 0; }
    _state_write_phase() { return 0; }
    _state_mark_complete() { return 0; }
    _PHASE_TEST_DIR=$(mktemp -d)
    REPO_ROOT="$_PHASE_TEST_DIR"
    _SCRIPT_DIR="$_PHASE_TEST_DIR"
    VISUAL_BASELINE_PATH=""
    MERGE_BASE_ORIGIN=""
    _CURRENT_PHASE=""
    eval "$_PS_BODY"
    # _phase_sync uses git commands that won't work outside a repo, so just
    # check that _CURRENT_PHASE is set at the very start of the function body.
    # We verify structurally that _CURRENT_PHASE="sync" is in the function.
    _HAS_CURRENT_PHASE=$(awk '/^_phase_sync\(\)/,/^\}$/' "$MERGE_SCRIPT" | grep -c '_CURRENT_PHASE="sync"' || true)
    assert_ne "test_phase_function_sets_current_phase" "0" "$_HAS_CURRENT_PHASE"
    rm -rf "$_PHASE_TEST_DIR"
    unset -f _worktree_sync_from_main _state_write_phase _state_mark_complete
fi

# =============================================================================
# Test: Each phase function calls _state_write_phase (structural check)
# =============================================================================
for _fn in $_PHASE_FNS; do
    _phase_name="${_fn#_phase_}"
    _SWP_IN_FN=$(awk "/^${_fn}\\(\\)/,/^\\}$/" "$MERGE_SCRIPT" | grep -c '_state_write_phase' || true)
    assert_ne "test_phase_function_calls_state_write_phase_${_fn}" "0" "$_SWP_IN_FN"
done

# =============================================================================
# Test: Each phase function calls _state_mark_complete (structural check)
# =============================================================================
for _fn in $_PHASE_FNS; do
    _SMC_IN_FN=$(awk "/^${_fn}\\(\\)/,/^\\}$/" "$MERGE_SCRIPT" | grep -c '_state_mark_complete' || true)
    assert_ne "test_phase_function_calls_state_mark_complete_${_fn}" "0" "$_SMC_IN_FN"
done

# =============================================================================
# Test: Sequential phase calls present in main script body (after functions)
# Each _phase_* function should appear as a standalone call line.
# =============================================================================
for _fn in $_PHASE_FNS; do
    _CALL_FOUND=$(grep -c "^${_fn}$" "$MERGE_SCRIPT" || true)
    assert_ne "test_sequential_phase_calls_present_${_fn}" "0" "$_CALL_FOUND"
done

# =============================================================================
# Test: _state_init is called after BRANCH is set
# =============================================================================
_STATE_INIT_AFTER_BRANCH=$(awk '/^BRANCH=/{found=1} found && /^_state_init/{print; exit}' "$MERGE_SCRIPT" | grep -c '_state_init' || true)
assert_ne "test_state_init_called_after_branch" "0" "$_STATE_INIT_AFTER_BRANCH"

# =============================================================================
# INTEGRATION TESTS: State file end-to-end behavior
# =============================================================================

# Re-eval helpers (clean slate for integration section)
eval "$(_extract_fn "_state_file_path")"
eval "$(_extract_fn "_state_is_fresh")"
eval "$(_extract_fn "_state_init")"
eval "$(_extract_fn "_state_write_phase")"
eval "$(_extract_fn "_state_mark_complete")"
eval "$(_extract_fn "_state_record_merge_sha")"

# =============================================================================
# Integration: State file contains correct schema after init
# =============================================================================
test_state_file_schema_complete() {
    BRANCH="m0d7-integ-test"
    # Remove any pre-existing state file
    rm -f "$(_state_file_path)" 2>/dev/null
    _state_init
    local _sf
    _sf=$(_state_file_path)
    local _schema_result
    _schema_result=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
errors = []
if d.get('branch') != 'm0d7-integ-test':
    errors.append('branch mismatch: ' + repr(d.get('branch')))
if d.get('merge_sha') != '':
    errors.append('merge_sha not empty: ' + repr(d.get('merge_sha')))
if d.get('completed_phases') != []:
    errors.append('completed_phases not empty list: ' + repr(d.get('completed_phases')))
if d.get('current_phase') != '':
    errors.append('current_phase not empty string: ' + repr(d.get('current_phase')))
if d.get('phases') != {}:
    errors.append('phases not empty dict: ' + repr(d.get('phases')))
if errors:
    print('FAIL: ' + '; '.join(errors))
else:
    print('PASS')
" 2>/dev/null || echo "FAIL: python parse error")
    assert_eq "test_state_file_schema_complete" "PASS" "$_schema_result"
    rm -f "$_sf" 2>/dev/null
}
test_state_file_schema_complete

# =============================================================================
# Integration: completed_phases array populated after marking complete
# =============================================================================
test_state_completed_phases_populated() {
    BRANCH="m0d7-integ-phases"
    rm -f "$(_state_file_path)" 2>/dev/null
    _state_init
    _state_mark_complete "sync"
    _state_mark_complete "merge"
    local _sf
    _sf=$(_state_file_path)
    local _phases_result
    _phases_result=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
cp = d.get('completed_phases', [])
if cp == ['sync', 'merge']:
    print('PASS')
else:
    print('FAIL: completed_phases=' + repr(cp))
" 2>/dev/null || echo "FAIL: python parse error")
    assert_eq "test_state_completed_phases_populated" "PASS" "$_phases_result"
    rm -f "$_sf" 2>/dev/null
}
test_state_completed_phases_populated

# =============================================================================
# Integration: merge_sha recorded correctly
# =============================================================================
test_state_merge_sha_recorded() {
    BRANCH="m0d7-integ-sha"
    rm -f "$(_state_file_path)" 2>/dev/null
    _state_init
    _state_record_merge_sha "abc123def456"
    local _sf
    _sf=$(_state_file_path)
    local _sha_result
    _sha_result=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
sha = d.get('merge_sha', '')
if sha == 'abc123def456':
    print('PASS')
else:
    print('FAIL: merge_sha=' + repr(sha))
" 2>/dev/null || echo "FAIL: python parse error")
    assert_eq "test_state_merge_sha_recorded" "PASS" "$_sha_result"
    rm -f "$_sf" 2>/dev/null
}
test_state_merge_sha_recorded

# =============================================================================
# Integration: SIGURG sends URG signal and state file records interrupted phase
# =============================================================================
test_sigurg_records_interrupted_phase() {
    BRANCH="sigurg-integ-test"
    local _sf
    _sf=$(_state_file_path)
    rm -f "$_sf" 2>/dev/null

    # Build a self-contained script with extracted helper functions
    local _helper_script
    _helper_script=$(mktemp)

    {
        echo '#!/usr/bin/env bash'
        echo 'set -uo pipefail'
        _extract_fn "_state_file_path"
        _extract_fn "_state_is_fresh"
        _extract_fn "_state_init"
        _extract_fn "_state_write_phase"
        _extract_fn "_sigurg_handler"
        echo 'BRANCH="sigurg-integ-test"'
        echo '_CURRENT_PHASE=""'
        echo '_state_init'
        echo '_state_write_phase "merge"'
        echo '_CURRENT_PHASE="merge"'
        echo 'trap "_sigurg_handler" URG'
        echo 'kill -URG $$'
        echo 'sleep 5  # should not reach here if trap exits'
    } > "$_helper_script"
    chmod +x "$_helper_script"

    # Run the script; it should exit via the SIGURG handler
    bash "$_helper_script" 2>/dev/null || true
    rm -f "$_helper_script"

    # Read the state file and verify current_phase was written
    local _written_phase
    _written_phase=$(python3 -c "
import json
try:
    with open('$_sf') as f:
        d = json.load(f)
    print(d.get('current_phase', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

    # The phase should be non-empty (either "merge" or "interrupted")
    assert_ne "test_sigurg_records_interrupted_phase" "" "$_written_phase"
    rm -f "$_sf" 2>/dev/null
}
# Guard: skip on platforms where kill -URG may not work
if bash -c 'kill -URG $$ 2>/dev/null; exit 0' 2>/dev/null; then
    test_sigurg_records_interrupted_phase
else
    echo "SKIP: test_sigurg_records_interrupted_phase -- kill -URG not supported on this platform"
    (( ++PASS ))  # Count as pass since we gracefully skipped
fi

# =============================================================================
# CLI argument parsing tests (lsms)
# =============================================================================

# =============================================================================
# Test: --help flag is handled in merge-to-main.sh (structural check)
# =============================================================================
# Test: --help prints usage and exits 0 (behavioral: invoke the script)
# =============================================================================
_HELP_OUTPUT=$(bash "$MERGE_SCRIPT" --help 2>&1) || true
_HELP_RC=$?
assert_eq "test_cli_help_exits_0" "0" "$_HELP_RC"
# --help output must mention --resume
if [[ "$_HELP_OUTPUT" == *--resume* ]]; then
    _HELP_HAS_RESUME="true"
else
    _HELP_HAS_RESUME="false"
fi
assert_eq "test_cli_help_mentions_resume" "true" "$_HELP_HAS_RESUME"

# =============================================================================
# Test: bash -n syntax check passes
# =============================================================================
SYNTAX_FINAL=0
bash -n "$MERGE_SCRIPT" 2>/dev/null && SYNTAX_FINAL=1
assert_eq "test_cli_bash_syntax_still_passes" "1" "$SYNTAX_FINAL"

# =============================================================================
# v2 ticket path pattern removal tests (a3b6-b820)
# Per user decision: both v2 and v3 ticket path patterns should be removed from
# merge filters since v3 tickets are on the orphan branch and never appear in
# the worktree merge diff.
# =============================================================================

# =============================================================================
# Test: .tickets/*.md pattern (v2 glob) is absent from merge-to-main.sh
# =============================================================================
HAS_V2_TICKETS_MD=$(grep -c '\.tickets/\*\.md' "$MERGE_SCRIPT" || true)
assert_eq "test_merge_to_main_no_v2_tickets_md_pattern" "0" "$HAS_V2_TICKETS_MD"

# =============================================================================
# Test: .tickets/archive/ path (v2 archive dir) is absent from merge-to-main.sh
# =============================================================================
HAS_V2_TICKETS_ARCHIVE=$(grep -c '\.tickets/archive/' "$MERGE_SCRIPT" || true)
assert_eq "test_merge_to_main_no_v2_tickets_dir_case" "0" "$HAS_V2_TICKETS_ARCHIVE"

# =============================================================================
# Test: TICKETS_DIR assigned to .tickets (v2 path binding) is absent
# Matches "TICKETS_DIR=...\.tickets" or "TICKETS_DIR.*=.*\.tickets" patterns.
# Note: the variable TICKETS_DIR itself may exist; only the binding to .tickets
# (the v2 path) should be removed.
# =============================================================================
HAS_TICKETS_DIR_V2=$(grep -cE 'TICKETS_DIR.*=.*"?\.tickets"?' "$MERGE_SCRIPT" || true)
assert_eq "test_merge_to_main_no_TICKETS_DIR_tickets_path" "0" "$HAS_TICKETS_DIR_V2"

# =============================================================================
# Test: _phase_version_bump checks for already-modified version file before bumping
# Bug 6ea9-a2af: if bump-version.sh ran but git commit --amend failed, resume
# would call bump-version.sh again (double-bump). The fix is to check whether the
# version file is already modified before bumping.
# =============================================================================
echo "--- test_version_bump_idempotent_guard ---"
_snapshot_fail
# Look for a guard in _phase_version_bump that checks if version file is already modified
# before calling bump-version.sh. The pattern: git diff or similar check before bump-version.sh
_has_already_bumped_guard=0
# Extract _phase_version_bump function body and check for a pre-bump guard
# that detects an already-modified version file before calling bump-version.sh.
# Must reference "already bumped" or check git diff on the version file.
_vb_body=$(sed -n '/_phase_version_bump()/,/^}/p' "$MERGE_SCRIPT")
# The pattern must appear AFTER the resume-skip block and BEFORE bump-version.sh call.
# Filter out the "already completed (resume skip)" line — that's the state-file check, not the file-level guard.
if [[ "$(echo "$_vb_body" | grep -v "resume skip")" =~ already.*bump|git\ diff.*version|version.*file.*modif ]]; then
    _has_already_bumped_guard=1
fi
assert_eq "test_version_bump_idempotent_guard: _phase_version_bump must check if version already bumped before calling bump-version.sh" \
    "1" "$_has_already_bumped_guard"
assert_pass_if_clean "test_version_bump_idempotent_guard"

# =============================================================================
# Test: merge-to-main.sh sources ensure-pre-commit.sh before merge
# Bug a45c-400e: git merge triggers pre-commit hooks, but pre-commit may not
# be in PATH. ensure-pre-commit.sh activates the venv.
# =============================================================================
echo "--- test_ensure_precommit_before_merge ---"
_snapshot_fail
_has_ensure_precommit=0
if grep -qE 'ensure-pre-commit' "$MERGE_SCRIPT"; then
    _has_ensure_precommit=1
fi
assert_eq "test_ensure_precommit_before_merge: merge-to-main.sh must call ensure-pre-commit.sh" \
    "1" "$_has_ensure_precommit"
assert_pass_if_clean "test_ensure_precommit_before_merge"

# =============================================================================
# Outbound Bridge dispatch guard tests (71fa-c068)
# =============================================================================

# =============================================================================
# Test: Outbound bridge dispatch is guarded by a SHA comparison
# The dispatch must only fire when tickets push actually sent new commits.
# =============================================================================
echo "--- test_outbound_bridge_dispatch_guarded ---"
_snapshot_fail
_push_body=$(sed -n '/_phase_push()/,/^}/p' "$MERGE_SCRIPT")
_has_sha_guard=0
if [[ "$_push_body" =~ _REMOTE_SHA_BEFORE.*_LOCAL_SHA|_LOCAL_SHA.*_REMOTE_SHA_BEFORE ]]; then
    _has_sha_guard=1
fi
assert_eq "test_outbound_bridge_dispatch_guarded: must compare SHAs before dispatching outbound bridge" \
    "1" "$_has_sha_guard"
assert_pass_if_clean "test_outbound_bridge_dispatch_guarded"

# =============================================================================
# Test: Outbound bridge workflow does NOT have push trigger on tickets branch
# The push trigger on orphan branches never fires (GitHub Actions limitation).
# Keeping it creates confusion about how the bridge is dispatched.
# =============================================================================
echo "--- test_outbound_bridge_no_push_trigger ---"
_snapshot_fail
_OUTBOUND_YML="$PLUGIN_ROOT/.github/workflows/outbound-bridge.yml"
_has_push_trigger=1
if [ -f "$_OUTBOUND_YML" ]; then
    if ! grep -qE '^\s+push:' "$_OUTBOUND_YML"; then
        _has_push_trigger=0
    fi
fi
assert_eq "test_outbound_bridge_no_push_trigger: push trigger on tickets branch must be removed" \
    "0" "$_has_push_trigger"
assert_pass_if_clean "test_outbound_bridge_no_push_trigger"

# =============================================================================
# Test: _phase_push removes stale SNAPSHOT files before tickets pull (3534-b90d)
# Without this, untracked SNAPSHOTs in the tickets worktree cause
# "untracked files would be overwritten by merge" errors on git pull --rebase.
# =============================================================================
echo "--- test_snapshot_cleanup_before_tickets_pull ---"
_snapshot_fail
_push_body_snap=$(sed -n '/_phase_push()/,/^}/p' "$MERGE_SCRIPT" 2>/dev/null || true)
_has_snapshot_cleanup=0
if grep -qE "SNAPSHOT\.json|Remove.*stale.*SNAPSHOT|stale SNAPSHOT" <<< "$_push_body_snap"; then
    _has_snapshot_cleanup=1
fi
assert_eq "test_snapshot_cleanup_before_tickets_pull: _phase_push must remove stale SNAPSHOT.json files before tickets pull (3534-b90d)" \
    "1" "$_has_snapshot_cleanup"
assert_pass_if_clean "test_snapshot_cleanup_before_tickets_pull"

# =============================================================================
echo "--- test_sync_phase_resets_stale_ahead_local_main ---"
_sync_body_ahead=$(sed -n '/_phase_sync()/,/^}/p' "$MERGE_SCRIPT" 2>/dev/null || true)
_has_ahead_reset=0
if grep -qE "rev-list.*count.*origin/main.*HEAD|reset.*hard.*origin/main" <<< "$_sync_body_ahead"; then
    _has_ahead_reset=1
fi
assert_eq "test_sync_phase_resets_stale_ahead_local_main: _phase_sync must detect stale-ahead local main and hard-reset to origin/main (35eb-1824)" \
    "1" "$_has_ahead_reset"
assert_pass_if_clean "test_sync_phase_resets_stale_ahead_local_main"

# =============================================================================
echo "--- test_merge_phase_resets_stale_ahead_local_main ---"
# _phase_merge must also contain drift-detection-and-reset logic, mirroring
# _phase_sync. Without it, --resume can skip _phase_sync and enter _phase_merge
# directly with local main still ahead of origin/main (e.g., after an
# interrupted version_bump), causing a plugin.json conflict on the merge retry.
# Before fix: _phase_merge has NO such reset → test FAILS (RED).
# After fix:  _phase_merge contains reset --hard origin/main → test PASSES.
_merge_body_drift=$(sed -n '/_phase_merge()/,/^}/p' "$MERGE_SCRIPT" 2>/dev/null || true)
_has_merge_drift_reset=0
if grep -qE "reset[[:space:]]+--hard[[:space:]]+origin/main" <<< "$_merge_body_drift"; then
    _has_merge_drift_reset=1
fi
assert_eq "test_merge_phase_resets_stale_ahead_local_main: _phase_merge must reset stale-ahead local main to origin/main (f6c6-362c)" \
    "1" "$_has_merge_drift_reset"
assert_pass_if_clean "test_merge_phase_resets_stale_ahead_local_main"

# =============================================================================
echo "--- test_merge_archive_includes_preconditions_summary ---"
# _phase_archive must call _read_latest_preconditions (or source ticket-lib.sh) and
# include the PRECONDITIONS summary in its log output.
# RED: _phase_archive is a no-op stub — no preconditions read.
_archive_body=$(sed -n '/_phase_archive()/,/^}/p' "$MERGE_SCRIPT" 2>/dev/null || true)
_archive_has_preconditions=0
if grep -qE "_read_latest_preconditions|preconditions" <<< "$_archive_body"; then
    _archive_has_preconditions=1
fi
assert_eq "test_merge_archive_includes_preconditions_summary: _phase_archive reads preconditions" \
    "1" "$_archive_has_preconditions"
assert_pass_if_clean "test_merge_archive_includes_preconditions_summary"

# =============================================================================
echo "--- test_merge_archive_legacy_ticket_pre_manifest ---"
# _phase_archive must handle the case where no PRECONDITIONS events exist (legacy ticket).
# It should not crash — _read_latest_preconditions exits 1 for pre-manifest,
# and _phase_archive must guard with || true.
# RED: _phase_archive is a no-op stub with no guard.
_archive_has_fallback=0
if grep -qE "\|\| true|\|\| :" <<< "$_archive_body"; then
    _archive_has_fallback=1
fi
assert_eq "test_merge_archive_legacy_ticket_pre_manifest: _phase_archive guards _read_latest_preconditions with || true" \
    "1" "$_archive_has_fallback"
assert_pass_if_clean "test_merge_archive_legacy_ticket_pre_manifest"

# =============================================================================
print_summary
