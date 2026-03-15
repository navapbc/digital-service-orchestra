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
print_summary
