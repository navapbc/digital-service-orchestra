#!/usr/bin/env bash
# tests/scripts/test-validate-test-batched-integration.sh
# TDD tests for validate.sh integration with test-batched.sh.
#
# Tests:
#   test_validate_test_step_uses_test_batched   — validate.sh invokes test-batched.sh for test step
#   test_validate_test_state_file_env_var        — VALIDATE_TEST_STATE_FILE env var is honored
#   test_validate_exits_2_on_partial_tests       — exit code 2 when tests are pending (not failed)
#   test_validate_reuses_passed_test_state       — if state file shows pass, tests step skipped
#   test_validate_test_pending_appears_in_output — "PENDING" label appears when tests not done
#
# Usage: bash tests/scripts/test-validate-test-batched-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
VALIDATE_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate.sh"
VALIDATE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/validate-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-test-batched-integration.sh ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ============================================================================
# test_validate_test_step_uses_test_batched
# Static analysis: validate.sh must reference test-batched.sh for the test step.
# This ensures the test runner is wrapped with the time-bounded harness.
# ============================================================================
echo ""
echo "=== test_validate_test_step_uses_test_batched ==="
_snapshot_fail

if grep -q "test-batched" "$VALIDATE_SCRIPT" 2>/dev/null; then
    USES_TEST_BATCHED="yes"
else
    USES_TEST_BATCHED="no"
fi
assert_eq "validate.sh references test-batched.sh" "yes" "$USES_TEST_BATCHED"

assert_pass_if_clean "test_validate_test_step_uses_test_batched"

# ============================================================================
# test_validate_test_state_file_env_var
# VALIDATE_TEST_STATE_FILE must be referenced in validate.sh.
# This env var allows callers and test-batched.sh to share a specific state
# file path across invocations, enabling session-level result reuse.
# ============================================================================
echo ""
echo "=== test_validate_test_state_file_env_var ==="
_snapshot_fail

if grep -q "VALIDATE_TEST_STATE_FILE" "$VALIDATE_SCRIPT" 2>/dev/null; then
    HAS_STATE_FILE_VAR="yes"
else
    HAS_STATE_FILE_VAR="no"
fi
assert_eq "validate.sh defines/uses VALIDATE_TEST_STATE_FILE env var" "yes" "$HAS_STATE_FILE_VAR"

assert_pass_if_clean "test_validate_test_state_file_env_var"

# ============================================================================
# test_validate_exits_2_on_partial_tests
# When test-batched.sh outputs "NEXT:" (partial completion), validate.sh
# must detect this and exit with code 2 (pending — not a hard failure).
#
# Strategy: Run validate.sh in a minimal fake environment where all non-test
# checks succeed instantly (stub commands = "true"), and the test step uses
# a stub test-batched.sh that simulates partial run (prints NEXT:, exits 0).
# Verify validate.sh exits 2.
# ============================================================================
echo ""
echo "=== test_validate_exits_2_on_partial_tests ==="
_snapshot_fail

# Create stub test-batched.sh that simulates partial completion
_stub_dir="$TMPDIR_TEST/stubs-partial"
mkdir -p "$_stub_dir"

_partial_state_file="$TMPDIR_TEST/test-state-partial-$$.json"

cat > "$_stub_dir/test-batched.sh" << STUB
#!/usr/bin/env bash
# Stub: simulates test-batched.sh partial completion (exits 0, emits ACTION REQUIRED block)
STATE_FILE="\${TEST_BATCHED_STATE_FILE:-/tmp/test-batched-state.json}"
python3 -c "
import json, time, os
state = {
    'runner': 'make test-unit-only',
    'completed': [],
    'results': {},
    'command_hash': 'stubhash',
    'created_at': int(time.time()),
    'signal_interrupted': True
}
d = os.path.dirname(os.path.abspath('\$STATE_FILE'))
if d:
    os.makedirs(d, exist_ok=True)
with open('\$STATE_FILE', 'w') as f:
    json.dump(state, f)
" 2>/dev/null || true
echo "0/1 tests completed."
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ⚠  ACTION REQUIRED — TESTS NOT COMPLETE  ⚠"
echo "════════════════════════════════════════════════════════════"
echo "RUN: TEST_BATCHED_STATE_FILE=\$STATE_FILE bash \$0 'make test-unit-only'"
echo "DO NOT PROCEED until the command above prints a final summary."
echo "════════════════════════════════════════════════════════════"
exit 0
STUB
chmod +x "$_stub_dir/test-batched.sh"

# Create a config file that maps all non-test check commands to "true" (instant pass).
# This isolates the test to only test the test-batched.sh integration.
_stub_config="$TMPDIR_TEST/stub-config-partial.conf"
cat > "$_stub_config" << 'CONF'
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=make test-unit-only
CONF

# Run validate.sh with:
# - config that maps all non-test checks to "true" (instant pass)
# - VALIDATE_TEST_BATCHED_SCRIPT points to our stub
# - VALIDATE_TEST_STATE_FILE points to an empty state (no cached pass)
# REVIEW-DEFENSE: CONFIG_FILE env var is a documented override recognized by
# validate.sh (line ~100: CONFIG_FILE="${CONFIG_FILE:-...}"). This ensures
# non-test checks (format, lint, etc.) use the stub config with `true` commands.
rc=0
output=""
output=$(
    VALIDATE_TEST_STATE_FILE="$_partial_state_file" \
    VALIDATE_TEST_BATCHED_SCRIPT="$_stub_dir/test-batched.sh" \
    VALIDATE_SKIP_PLUGIN_CHECKS=1 \
    CONFIG_FILE="$_stub_config" \
    bash "$VALIDATE_SCRIPT" \
    2>&1
) || rc=$?

# validate.sh must exit 2 when tests are pending
assert_eq "test_validate_exits_2_on_partial_tests exits 2 (pending)" "2" "$rc"

# Bug dso-w7bs: verify the state file was written with expected partial content
if [[ -f "$_partial_state_file" ]]; then
    _state_has_interrupted=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('yes' if d.get('signal_interrupted') else 'no')
" "$_partial_state_file" 2>/dev/null || echo "error")
    assert_eq "test_validate_exits_2_on_partial_tests state file has signal_interrupted" "yes" "$_state_has_interrupted"
else
    (( ++FAIL ))
    echo "FAIL: test_validate_exits_2_on_partial_tests — state file not created at $_partial_state_file" >&2
fi

assert_pass_if_clean "test_validate_exits_2_on_partial_tests"

# ============================================================================
# test_validate_reuses_passed_test_state
# When a test-batched state file shows "pass" for the test command,
# validate.sh must skip re-running the test command (reuse cached result).
#
# Static analysis approach: validate.sh must contain code that:
# 1. Reads VALIDATE_TEST_STATE_FILE
# 2. Checks for "pass" result in the state
# 3. Skips test execution when pass is found
#
# We verify this by checking the code structure statically.
# ============================================================================
echo ""
echo "=== test_validate_reuses_passed_test_state ==="
_snapshot_fail

# validate.sh must read the test state file (VALIDATE_TEST_STATE_FILE)
# and skip tests when they already passed
_reads_state_file=$(grep -c "VALIDATE_TEST_STATE_FILE" "$VALIDATE_SCRIPT" 2>/dev/null; true)
_reads_count="${_reads_state_file:-0}"
if [[ "$_reads_count" =~ ^[0-9]+$ ]] && [ "$_reads_count" -ge 2 ]; then
    # At least 2 references: definition + usage
    READS_STATE="yes"
else
    READS_STATE="no (found only ${_reads_count} reference(s))"
fi
assert_eq "validate.sh reads VALIDATE_TEST_STATE_FILE in multiple places" "yes" "$READS_STATE"

# validate.sh must skip test execution when state shows pass
# Check for a "pass" check pattern near the test invocation
if grep -q "tests.*pass\|pass.*skip\|skip.*test\|already.*pass\|reuse\|cached" "$VALIDATE_SCRIPT" 2>/dev/null; then
    HAS_REUSE_LOGIC="yes"
else
    HAS_REUSE_LOGIC="no"
fi
assert_eq "validate.sh has test result reuse/skip logic" "yes" "$HAS_REUSE_LOGIC"

assert_pass_if_clean "test_validate_reuses_passed_test_state"

# ============================================================================
# test_validate_test_pending_appears_in_output
# When tests are pending (partial run), validate.sh output must include
# guidance that tests are pending and how to resume.
# Static analysis: validate.sh must print a "PENDING" label specifically
# for the tests step (not CI pending), along with resume instructions.
# We check for the pattern: tests: PENDING or similar in the report_check/
# test step reporting section.
# ============================================================================
echo ""
echo "=== test_validate_test_pending_appears_in_output ==="
_snapshot_fail

# The output for a pending test step should contain "PENDING" as part of the
# tests: status line — e.g., "tests:   PENDING (run again to continue)".
# We specifically look for "PENDING" in the context of test reporting
# (not CI comments). The implementation must print a message containing
# "PENDING" from the tests report section.
if grep -q 'tests.*PENDING\|PENDING.*run.*again\|run.*validate.sh.*again' "$VALIDATE_SCRIPT" 2>/dev/null; then
    HAS_PENDING_MSG="yes"
else
    HAS_PENDING_MSG="no"
fi
assert_eq "validate.sh contains PENDING message for partial test runs" "yes" "$HAS_PENDING_MSG"

assert_pass_if_clean "test_validate_test_pending_appears_in_output"

# ============================================================================
# test_validate_detects_action_required_block
# validate.sh must detect partial test-batched.sh runs by matching the new
# Structured Action-Required Block format ("ACTION REQUIRED") rather than the
# old "NEXT:" plain-text line.
# ============================================================================
echo ""
echo "=== test_validate_detects_action_required_block ==="
_snapshot_fail

if grep -qE "ACTION.REQUIRED|action.required" "$VALIDATE_SCRIPT" 2>/dev/null; then
    HAS_ACTION_REQUIRED_GREP="yes"
else
    HAS_ACTION_REQUIRED_GREP="no"
fi
assert_eq "validate.sh greps for ACTION REQUIRED (updated pattern)" "yes" "$HAS_ACTION_REQUIRED_GREP"

assert_pass_if_clean "test_validate_detects_action_required_block"

# ============================================================================
# test_validate_emits_action_required_block_on_exit_2
# When tests are pending (exit 2), validate.sh must emit the Structured
# Action-Required Block to stdout so agents cannot miss the continuation prompt.
# ============================================================================
echo ""
echo "=== test_validate_emits_action_required_block_on_exit_2 ==="
_snapshot_fail

# Create stub test-batched.sh that simulates partial completion using the
# new Structured Action-Required Block format.
_stub_dir_e2="$TMPDIR_TEST/stubs-e2"
mkdir -p "$_stub_dir_e2"

_partial_state_file_e2="$TMPDIR_TEST/test-state-e2-$$.json"

cat > "$_stub_dir_e2/test-batched.sh" << STUB
#!/usr/bin/env bash
# Stub: simulates partial completion with Structured Action-Required Block
STATE_FILE="\${TEST_BATCHED_STATE_FILE:-/tmp/test-batched-state.json}"
python3 -c "
import json, time, os
state = {
    'runner': 'make test-unit-only',
    'completed': [],
    'results': {},
    'command_hash': 'stubhash',
    'created_at': int(time.time()),
    'signal_interrupted': True
}
d = os.path.dirname(os.path.abspath('\$STATE_FILE'))
if d:
    os.makedirs(d, exist_ok=True)
with open('\$STATE_FILE', 'w') as f:
    json.dump(state, f)
" 2>/dev/null || true
echo "0/1 tests completed."
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ⚠  ACTION REQUIRED — TESTS NOT COMPLETE  ⚠"
echo "════════════════════════════════════════════════════════════"
echo "RUN: TEST_BATCHED_STATE_FILE=\$STATE_FILE bash \$0 'make test-unit-only'"
echo "DO NOT PROCEED until the command above prints a final summary."
echo "════════════════════════════════════════════════════════════"
exit 0
STUB
chmod +x "$_stub_dir_e2/test-batched.sh"

_stub_config_e2="$TMPDIR_TEST/stub-config-e2.conf"
cat > "$_stub_config_e2" << 'CONF'
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=make test-unit-only
CONF

rc_e2=0
output_e2=""
output_e2=$(
    VALIDATE_TEST_STATE_FILE="$_partial_state_file_e2" \
    VALIDATE_TEST_BATCHED_SCRIPT="$_stub_dir_e2/test-batched.sh" \
    VALIDATE_SKIP_PLUGIN_CHECKS=1 \
    CONFIG_FILE="$_stub_config_e2" \
    bash "$VALIDATE_SCRIPT" \
    2>&1
) || rc_e2=$?

# validate.sh must exit 2 when tests are pending
assert_eq "test_validate_emits_action_required_block_on_exit_2: exits 2" "2" "$rc_e2"

# validate.sh stdout must contain "ACTION REQUIRED"
e2_has_action=0
[[ "$output_e2" == *"ACTION REQUIRED"* ]] && e2_has_action=1
assert_eq "test_validate_emits_action_required_block_on_exit_2: output contains 'ACTION REQUIRED'" "1" "$e2_has_action"

assert_pass_if_clean "test_validate_emits_action_required_block_on_exit_2"

# ============================================================================
# test_validate_rejects_state_file_missing_command_hash
# Bug dso-gjww: _test_state_already_passed must reject state files that lack
# a command_hash field, since they could belong to a different test command.
# ============================================================================
_snapshot_fail

# The _test_state_already_passed function in validate.sh must reject state files
# with missing command_hash. Verify that the Python code block inside the function
# uses "not stored_hash" (reject empty) rather than "stored_hash and ..." (skip empty).
# This is a structural test — it verifies the fix pattern is present in the source.
_tmp=$(sed -n '/_test_state_already_passed/,/^}/p' "$VALIDATE_SCRIPT")
# _test_state_already_passed may have been extracted to validate-helpers.sh
if [[ -z "$_tmp" ]] && [[ -f "${VALIDATE_HELPERS_LIB:-}" ]]; then
    _tmp=$(sed -n '/_test_state_already_passed/,/^}/p' "$VALIDATE_HELPERS_LIB")
fi
if grep -q 'not stored_hash' <<< "$_tmp"; then
    _nohash_actual="rejects_missing"
else
    _nohash_actual="accepts_missing"
fi
assert_eq "test_validate_rejects_state_file_missing_command_hash: rejects missing hash" "rejects_missing" "$_nohash_actual"

assert_pass_if_clean "test_validate_rejects_state_file_missing_command_hash"

# ============================================================================
# test_validate_check_runners_cmd_test_dirs_routing
# Behavioral: when commands.test_dirs is set in config, validate.sh must invoke
# test-batched.sh with --runner=bash and --test-dir=<value>. A stub test-batched.sh
# records the arguments it receives; we assert the recorded args contain --runner=bash.
# Introduced to fix the infinite PENDING loop (bug bf39-4494).
# ============================================================================
echo ""
echo "=== test_validate_check_runners_cmd_test_dirs_routing ==="
_snapshot_fail

_cmd_test_dirs_tmpdir="$TMPDIR_TEST/cmd-test-dirs-test"
mkdir -p "$_cmd_test_dirs_tmpdir/stubs" "$_cmd_test_dirs_tmpdir/testdir"

# Stub test-batched.sh: records args to a file and exits 0 (clean pass)
_args_record="$_cmd_test_dirs_tmpdir/recorded-args.txt"
cat > "$_cmd_test_dirs_tmpdir/stubs/test-batched.sh" << STUB
#!/usr/bin/env bash
echo "\$@" > "$_args_record"
echo "All tests done. 0/0 tests completed. 0 passed, 0 failed, 0 interrupted."
exit 0
STUB
chmod +x "$_cmd_test_dirs_tmpdir/stubs/test-batched.sh"

_cmd_state_file="$_cmd_test_dirs_tmpdir/state.json"
_cmd_config="$_cmd_test_dirs_tmpdir/stub-config.conf"
cat > "$_cmd_config" << CONF
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=bash tests/run-all.sh
commands.test_dirs=$_cmd_test_dirs_tmpdir/testdir
CONF

VALIDATE_TEST_STATE_FILE="$_cmd_state_file" \
VALIDATE_TEST_BATCHED_SCRIPT="$_cmd_test_dirs_tmpdir/stubs/test-batched.sh" \
VALIDATE_SKIP_PLUGIN_CHECKS=1 \
CONFIG_FILE="$_cmd_config" \
bash "$VALIDATE_SCRIPT" >/dev/null 2>&1 || true

_recorded_args=""
[ -f "$_args_record" ] && _recorded_args=$(cat "$_args_record")

# The stub must have been called with --runner=bash
if echo "$_recorded_args" | grep -q "\-\-runner=bash"; then
    _runner_bash_present="yes"
else
    _runner_bash_present="no"
fi

# The stub must have been called with --test-dir pointing to the configured dir
if echo "$_recorded_args" | grep -q "\-\-test-dir="; then
    _test_dir_present="yes"
else
    _test_dir_present="no"
fi

assert_eq "validate routes to --runner=bash when CMD_TEST_DIRS is set" "yes" "$_runner_bash_present"
assert_eq "validate passes --test-dir= when CMD_TEST_DIRS is set" "yes" "$_test_dir_present"

assert_pass_if_clean "test_validate_check_runners_cmd_test_dirs_routing"

# ============================================================================
# test_validate_state_already_passed_rejects_timeout_exceeded
# Behavioral: _test_state_already_passed must NOT treat a state file containing
# 'interrupted-timeout-exceeded' as a passing run. Without this check, validate.sh
# would skip re-running tests even when a test was killed by PER_TEST_TIMEOUT,
# silently hiding the timeout (bug bf39-4494 follow-on).
# ============================================================================
echo ""
echo "=== test_validate_state_already_passed_rejects_timeout_exceeded ==="
_snapshot_fail

_timeout_exceeded_tmpdir="$TMPDIR_TEST/timeout-exceeded-test"
mkdir -p "$_timeout_exceeded_tmpdir/stubs"

# State file that has one pass and one interrupted-timeout-exceeded result
_timeout_state_cmd="bash tests/run-all.sh"
_timeout_state_cmd_hash=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "${_timeout_state_cmd}:$(pwd)")
_timeout_state_file="$_timeout_exceeded_tmpdir/state.json"
python3 - "$_timeout_state_cmd_hash" "$_timeout_state_file" << 'PYEOF'
import json, sys, time
cmd_hash, state_file = sys.argv[1], sys.argv[2]
state = {
    "runner": "bash",
    "completed": ["tests/fast.sh", "tests/slow.sh"],
    "results": {"tests/fast.sh": "pass", "tests/slow.sh": "interrupted-timeout-exceeded"},
    "command_hash": cmd_hash,
    "created_at": int(time.time())
}
with open(state_file, "w") as f:
    json.dump(state, f)
PYEOF

# Stub test-batched.sh: records whether it was called (non-call = false cache hit)
_timeout_was_called="$_timeout_exceeded_tmpdir/was-called.txt"
cat > "$_timeout_exceeded_tmpdir/stubs/test-batched.sh" << STUB
#!/usr/bin/env bash
echo "called" > "$_timeout_was_called"
echo "All tests done. 2/2 tests completed. 1 passed, 0 failed, 0 interrupted, 1 timed-out."
exit 1
STUB
chmod +x "$_timeout_exceeded_tmpdir/stubs/test-batched.sh"

_timeout_config="$_timeout_exceeded_tmpdir/stub-config.conf"
cat > "$_timeout_config" << CONF
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=$_timeout_state_cmd
CONF

VALIDATE_TEST_STATE_FILE="$_timeout_state_file" \
VALIDATE_TEST_BATCHED_SCRIPT="$_timeout_exceeded_tmpdir/stubs/test-batched.sh" \
VALIDATE_SKIP_PLUGIN_CHECKS=1 \
CONFIG_FILE="$_timeout_config" \
bash "$VALIDATE_SCRIPT" >/dev/null 2>&1 || true

# The stub must have been called — if not, validate.sh falsely treated the
# interrupted-timeout-exceeded state as a cached pass
if [ -f "$_timeout_was_called" ]; then
    _rerun_happened="yes"
else
    _rerun_happened="no"
fi

assert_eq "validate re-runs tests when state has interrupted-timeout-exceeded" "yes" "$_rerun_happened"

assert_pass_if_clean "test_validate_state_already_passed_rejects_timeout_exceeded"

print_summary
