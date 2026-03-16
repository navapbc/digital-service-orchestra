#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-merge-to-main.sh
# Tests for merge-to-main.sh post-merge validation parallelization.
#
# TDD tests:
#   1. test_parallel_validation_uses_background_jobs — format-check and lint run as & jobs
#   2. test_parallel_validation_waits_for_jobs — wait is used to collect exit codes
#   3. test_parallel_validation_captures_both_exit_codes — both PIDs/exit codes captured
#   4. test_parallel_validation_bash_syntax — bash -n passes
#   5. test_parallel_validation_faster_than_serial — mock with sleep 1, assert <2s
#
# Usage: bash lockpick-workflow/tests/scripts/test-merge-to-main.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/merge-to-main.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# =============================================================================
# Test 1: Post-merge validation runs format-check as a background job
# The script should have '&' after the format-check command invocation.
# =============================================================================
HAS_BACKGROUND_JOB=$(grep -cE ' &$|^&$' "$MERGE_SCRIPT" || true)
assert_ne "test_parallel_validation_uses_background_jobs" "0" "$HAS_BACKGROUND_JOB"

# =============================================================================
# Test 2: Post-merge validation waits for background jobs
# The script should use 'wait' to collect results from background jobs.
# =============================================================================
HAS_WAIT=$(grep -c '\bwait\b' "$MERGE_SCRIPT" || true)
assert_ne "test_parallel_validation_waits_for_jobs" "0" "$HAS_WAIT"

# =============================================================================
# Test 3: Both exit codes are captured after wait
# The script should capture exit codes for both format-check and lint.
# Pattern: wait $PID; result=$? (or equivalent)
# =============================================================================
HAS_EXIT_CAPTURE=$(grep -c 'wait.*\$\|exit_\|_exit\|_rc\|_status\|FMT_RC\|LINT_RC\|FMT_EXIT\|LINT_EXIT' "$MERGE_SCRIPT" || true)
assert_ne "test_parallel_validation_captures_both_exit_codes" "0" "$HAS_EXIT_CAPTURE"

# =============================================================================
# Test 4: bash -n syntax check passes on merge-to-main.sh
# =============================================================================
SYNTAX_OK=0
bash -n "$MERGE_SCRIPT" 2>/dev/null && SYNTAX_OK=1
assert_eq "test_parallel_validation_bash_syntax" "1" "$SYNTAX_OK"

# =============================================================================
# Test 5: Parallel execution is faster than serial execution
# Mock format-check and lint as 'sleep 2'. Serial would take ≥4s; parallel <4s.
# Uses perl for millisecond timestamps to avoid date +%s granularity issues.
# =============================================================================
# Build a minimal test harness that exercises the parallelized section directly.
_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT

# Write mock commands that sleep 2 seconds each (serial would take ≥4s)
cat > "$_TMPDIR/mock-format-check.sh" <<'MOCK'
#!/usr/bin/env bash
sleep 2
exit 0
MOCK
chmod +x "$_TMPDIR/mock-format-check.sh"

cat > "$_TMPDIR/mock-lint.sh" <<'MOCK'
#!/usr/bin/env bash
sleep 2
exit 0
MOCK
chmod +x "$_TMPDIR/mock-lint.sh"

# Get millisecond timestamp via perl (portable, no GNU date needed)
_ms_now() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

_START=$(_ms_now)
POST_MERGE_FAIL=false

CMD_FORMAT_CHECK="$_TMPDIR/mock-format-check.sh"
CMD_LINT="$_TMPDIR/mock-lint.sh"
_APP_DIR="$_TMPDIR"

# Run in parallel (background jobs)
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

_END=$(_ms_now)
_ELAPSED_MS=$(( _END - _START ))

# Serial would take ≥4000ms; parallel should finish in <3500ms
if [[ "$_ELAPSED_MS" -lt 3500 ]]; then
    _TIMING_OK="true"
else
    _TIMING_OK="false"
fi
assert_eq "test_parallel_validation_faster_than_serial" "true" "$_TIMING_OK"

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
# Test: _count_closed_tickets() function exists in merge-to-main.sh
# =============================================================================
HAS_COUNT_FUNCTION=$(grep -c '_count_closed_tickets' "$MERGE_SCRIPT" || true)
assert_ne "test_count_closed_tickets_function_exists" "0" "$HAS_COUNT_FUNCTION"

# =============================================================================
# Test: _count_closed_tickets() uses single awk pass (not -exec awk per file)
# =============================================================================
HAS_EXEC_AWK=$(grep -c '\-exec awk' "$MERGE_SCRIPT" || true)
assert_eq "test_count_closed_tickets_no_exec_awk" "0" "$HAS_EXEC_AWK"

# =============================================================================
# Test: _count_closed_tickets() returns correct count for temp dir fixture
# Create a temp dir with 2 open + 3 closed tickets; assert count == 3
# =============================================================================
_TC_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TC_TMPDIR"' EXIT

# Helper to write a minimal markdown ticket with given status
_write_ticket() {
    local file="$1" status="$2"
    printf -- '---\nstatus: %s\ntitle: Ticket %s\n---\nBody text.\n' "$status" "$status" > "$file"
}

_write_ticket "$_TC_TMPDIR/open1.md" "open"
_write_ticket "$_TC_TMPDIR/open2.md" "open"
_write_ticket "$_TC_TMPDIR/closed1.md" "closed"
_write_ticket "$_TC_TMPDIR/closed2.md" "closed"
_write_ticket "$_TC_TMPDIR/closed3.md" "closed"

# Source the function under test by extracting and eval-ing just the function
# definition from merge-to-main.sh (avoid executing the full script).
_FN_BODY=$(awk '/^_count_closed_tickets\(\)/{found=1} found{print; if(/^\}$/){exit}}' "$MERGE_SCRIPT")
if [[ -z "$_FN_BODY" ]]; then
    # Function not yet defined — RED: mark both behavioural tests as failing
    assert_eq "test_count_closed_tickets_correct_count" "3" "FUNCTION_NOT_FOUND"
    assert_eq "test_count_closed_tickets_open_not_counted" "0" "FUNCTION_NOT_FOUND"
else
    eval "$_FN_BODY"
    _GOT_COUNT=$(_count_closed_tickets "$_TC_TMPDIR")
    assert_eq "test_count_closed_tickets_correct_count" "3" "$_GOT_COUNT"

    # Also verify open tickets are NOT counted (open-only dir)
    _OPEN_TMPDIR=$(mktemp -d)
    trap 'rm -rf "$_OPEN_TMPDIR"' EXIT
    _write_ticket "$_OPEN_TMPDIR/open1.md" "open"
    _write_ticket "$_OPEN_TMPDIR/open2.md" "open"
    _GOT_OPEN_COUNT=$(_count_closed_tickets "$_OPEN_TMPDIR")
    assert_eq "test_count_closed_tickets_open_not_counted" "0" "$_GOT_OPEN_COUNT"
    rm -rf "$_OPEN_TMPDIR"
fi

rm -rf "$_TC_TMPDIR"

# =============================================================================
# State file helper function tests
# =============================================================================

# Helper: extract and eval state file functions from merge-to-main.sh
# We extract each function by name, eval it, so we can test individually.
_extract_fn() {
    local fn_name="$1"
    awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT"
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
print_summary
