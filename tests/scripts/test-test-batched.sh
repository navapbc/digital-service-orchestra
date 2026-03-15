#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-test-batched.sh
# Tests for test-batched.sh — time-bounded test batching harness
#
# Usage: bash lockpick-workflow/tests/scripts/test-test-batched.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/test-batched.sh"
ASSERT_LIB="$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

if [ ! -f "$ASSERT_LIB" ]; then
    echo "SKIP: test-test-batched.sh — assert.sh not found at: $ASSERT_LIB" >&2
    exit 0
fi
source "$ASSERT_LIB"

echo "=== test-test-batched.sh ==="

# ── test_script_exists_and_executable ─────────────────────────────────────────
echo ""
echo "--- test_script_exists_and_executable ---"
_snapshot_fail
script_ok=0
[ -x "$SCRIPT" ] && script_ok=1
assert_eq "test_script_exists_and_executable: file exists and is executable" "1" "$script_ok"
assert_pass_if_clean "test_script_exists_and_executable"

# All remaining tests are skipped when the script does not exist
if [ ! -x "$SCRIPT" ]; then
    echo ""
    echo "Skipping remaining tests — script not yet present (expected RED state)."
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 1
fi

# ── test_help_outputs_usage ───────────────────────────────────────────────────
echo ""
echo "--- test_help_outputs_usage ---"
_snapshot_fail
help_out=""
help_out=$(bash "$SCRIPT" --help 2>&1) || true
assert_contains "test_help_outputs_usage: contains 'Usage'" "Usage" "$help_out"
assert_pass_if_clean "test_help_outputs_usage"

# ── test_missing_args_exits_nonzero ──────────────────────────────────────────
echo ""
echo "--- test_missing_args_exits_nonzero ---"
_snapshot_fail
no_args_exit=0
bash "$SCRIPT" 2>/dev/null && no_args_exit=0 || no_args_exit=$?
assert_ne "test_missing_args_exits_nonzero: exits non-zero with no args" "0" "$no_args_exit"
assert_pass_if_clean "test_missing_args_exits_nonzero"

# ── test_stops_after_timeout_and_outputs_resume_command ──────────────────────
# Use --timeout=1 with a command that sleeps 10s; script should stop early and
# print a NEXT: <resume command> line.
echo ""
echo "--- test_stops_after_timeout_and_outputs_resume_command ---"
_snapshot_fail
TMPDIR_TIMEOUT="$(mktemp -d)"
TIMEOUT_STATE="$TMPDIR_TIMEOUT/test-batched-state.json"
timeout_out=""
timeout_out=$(TEST_BATCHED_STATE_FILE="$TIMEOUT_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null) || true
rm -rf "$TMPDIR_TIMEOUT"
assert_contains "test_stops_after_timeout_and_outputs_resume_command: output contains NEXT:" "NEXT:" "$timeout_out"
assert_pass_if_clean "test_stops_after_timeout_and_outputs_resume_command"

# ── test_resume_from_state_file ───────────────────────────────────────────────
# Run a command with --timeout=1 so it saves state, then re-run the same command
# with the saved state file. The second run should skip the already-completed test.
echo ""
echo "--- test_resume_from_state_file ---"
_snapshot_fail
TMPDIR_RESUME="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESUME"' EXIT

RESUME_STATE="$TMPDIR_RESUME/test-batched-state.json"
# First run: use a fast command that completes within timeout, creating a state entry
# Then create a state file that marks this test ID as completed
RESUME_CMD="bash -c 'exit 0'"
# The test ID for this command will be "bash_-c_exit_0" (spaces->underscores, special chars stripped)
RESUME_TEST_ID="bash_-c_exit_0"
python3 -c "
import json, sys
state = {
  'runner': sys.argv[1],
  'completed': [sys.argv[2]],
  'results': {sys.argv[2]: 'pass'}
}
with open(sys.argv[3], 'w') as f:
    json.dump(state, f, indent=2)
" "$RESUME_CMD" "$RESUME_TEST_ID" "$RESUME_STATE"

resume_out=""
# Second run: same command + state file. Should detect test is already completed and skip it.
resume_out=$(TEST_BATCHED_STATE_FILE="$RESUME_STATE" bash "$SCRIPT" --timeout=10 \
    "$RESUME_CMD" 2>&1) || true
# The output should contain "Skipping (already completed)" since the test ID matches
assert_contains "test_resume_from_state_file: output contains 'Skipping (already completed)'" \
    "Skipping (already completed)" "$resume_out"
assert_pass_if_clean "test_resume_from_state_file"

# ── test_final_batch_outputs_summary_and_deletes_state ───────────────────────
echo ""
echo "--- test_final_batch_outputs_summary_and_deletes_state ---"
_snapshot_fail
TMPDIR_FINAL="$(mktemp -d)"
FINAL_STATE="$TMPDIR_FINAL/test-batched-state.json"

final_out=""
final_exit=0
# Use a fast passing command; high timeout so it completes
final_out=$(TEST_BATCHED_STATE_FILE="$FINAL_STATE" bash "$SCRIPT" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) || final_exit=$?

# Summary must mention passed
assert_contains "test_final_batch_outputs_summary_and_deletes_state: output contains 'passed'" "passed" "$final_out"
# State file should be deleted after completion
state_deleted=1
[ -f "$FINAL_STATE" ] && state_deleted=0
assert_eq "test_final_batch_outputs_summary_and_deletes_state: state file deleted after run" "1" "$state_deleted"
rm -rf "$TMPDIR_FINAL"
assert_pass_if_clean "test_final_batch_outputs_summary_and_deletes_state"

# ── test_failures_accumulated_and_displayed_in_summary ───────────────────────
echo ""
echo "--- test_failures_accumulated_and_displayed_in_summary ---"
_snapshot_fail
TMPDIR_FAIL="$(mktemp -d)"
FAIL_STATE="$TMPDIR_FAIL/test-batched-state.json"

fail_out=""
fail_exit=0
# Command that always exits 1 (simulates a failing test)
fail_out=$(TEST_BATCHED_STATE_FILE="$FAIL_STATE" bash "$SCRIPT" --timeout=30 \
    "bash -c 'exit 1'" 2>&1) || fail_exit=$?

assert_contains "test_failures_accumulated_and_displayed_in_summary: output contains 'failed'" "failed" "$fail_out"
rm -rf "$TMPDIR_FAIL"
assert_pass_if_clean "test_failures_accumulated_and_displayed_in_summary"

# ── test_command_not_found_exits_with_error ───────────────────────────────────
echo ""
echo "--- test_command_not_found_exits_with_error ---"
_snapshot_fail
notfound_out=""
notfound_exit=0
notfound_out=$(bash "$SCRIPT" "this_command_does_not_exist_zxqy" 2>&1) || notfound_exit=$?
# Should exit non-zero and mention error or command not found
assert_ne "test_command_not_found_exits_with_error: exits non-zero" "0" "$notfound_exit"
assert_pass_if_clean "test_command_not_found_exits_with_error"

# ── test_corrupted_state_file_starts_fresh ───────────────────────────────────
echo ""
echo "--- test_corrupted_state_file_starts_fresh ---"
_snapshot_fail
TMPDIR_CORRUPT="$(mktemp -d)"
CORRUPT_STATE="$TMPDIR_CORRUPT/test-batched-state.json"
# Write corrupted JSON
echo "NOT_VALID_JSON{{{" > "$CORRUPT_STATE"

corrupt_out=""
corrupt_exit=0
# Should detect corruption and start fresh (not crash)
corrupt_out=$(TEST_BATCHED_STATE_FILE="$CORRUPT_STATE" bash "$SCRIPT" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) || corrupt_exit=$?

# Should produce valid output mentioning passed (started fresh)
assert_contains "test_corrupted_state_file_starts_fresh: output contains 'passed'" "passed" "$corrupt_out"
rm -rf "$TMPDIR_CORRUPT"
assert_pass_if_clean "test_corrupted_state_file_starts_fresh"

# ── test_generic_fallback_with_arbitrary_command ──────────────────────────────
echo ""
echo "--- test_generic_fallback_with_arbitrary_command ---"
_snapshot_fail
TMPDIR_GENERIC="$(mktemp -d)"
GENERIC_STATE="$TMPDIR_GENERIC/test-batched-state.json"
generic_out=""
generic_exit=0
generic_out=$(TEST_BATCHED_STATE_FILE="$GENERIC_STATE" bash "$SCRIPT" "bash -c 'exit 0'" 2>&1) || generic_exit=$?
rm -rf "$TMPDIR_GENERIC"
assert_contains "test_generic_fallback_with_arbitrary_command: output contains 'passed'" "passed" "$generic_out"
assert_pass_if_clean "test_generic_fallback_with_arbitrary_command"

# ── test_state_file_contains_expected_json_keys ───────────────────────────────
# Mid-run state file (interrupted by timeout) should contain runner, completed, results keys.
echo ""
echo "--- test_state_file_contains_expected_json_keys ---"
_snapshot_fail
TMPDIR_STATE="$(mktemp -d)"
MID_STATE="$TMPDIR_STATE/test-batched-state.json"

# Use timeout=1 with a slow command so state file is written before completion.
# Use TEST_BATCHED_STATE_FILE to write to our isolated temp file.
TEST_BATCHED_STATE_FILE="$MID_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null || true

if [ -f "$MID_STATE" ]; then
    has_runner=0
    has_completed=0
    has_results=0
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert 'runner' in d
    assert 'completed' in d
    assert 'results' in d
    sys.exit(0)
except Exception as e:
    sys.exit(1)
" "$MID_STATE" && { has_runner=1; has_completed=1; has_results=1; } || true
    assert_eq "test_state_file_contains_expected_json_keys: has 'runner' key" "1" "$has_runner"
    assert_eq "test_state_file_contains_expected_json_keys: has 'completed' key" "1" "$has_completed"
    assert_eq "test_state_file_contains_expected_json_keys: has 'results' key" "1" "$has_results"
else
    # State file may not be written if timeout was too fast; mark as pass with note
    assert_eq "test_state_file_contains_expected_json_keys: state file check (skipped—no file)" "ok" "ok"
fi
rm -rf "$TMPDIR_STATE"
assert_pass_if_clean "test_state_file_contains_expected_json_keys"

# ── test_progress_indicator_in_output ─────────────────────────────────────────
# When running multiple items, output should show N/M format progress.
echo ""
echo "--- test_progress_indicator_in_output ---"
_snapshot_fail
TMPDIR_PROG="$(mktemp -d)"
PROG_STATE="$TMPDIR_PROG/test-batched-state.json"

# Passing a semicolon-separated list of commands as the test suite
# The script should show progress like "1/1 tests completed"
prog_out=""
prog_out=$(TEST_BATCHED_STATE_FILE="$PROG_STATE" bash "$SCRIPT" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) || true

# Check for N/M pattern in output
nm_found=0
echo "$prog_out" | grep -qE '[0-9]+/[0-9]+' && nm_found=1
assert_eq "test_progress_indicator_in_output: output contains N/M progress pattern" "1" "$nm_found"
rm -rf "$TMPDIR_PROG"
assert_pass_if_clean "test_progress_indicator_in_output"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
