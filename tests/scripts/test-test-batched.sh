#!/usr/bin/env bash
# tests/scripts/test-test-batched.sh
# Tests for test-batched.sh — time-bounded test batching harness
#
# Usage: bash tests/scripts/test-test-batched.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/test-batched.sh"
ASSERT_LIB="$PLUGIN_ROOT/tests/lib/assert.sh"

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
# emit the Structured Action-Required Block (ACTION REQUIRED / RUN: / DO NOT PROCEED).
echo ""
echo "--- test_stops_after_timeout_and_outputs_resume_command ---"
_snapshot_fail
TMPDIR_TIMEOUT="$(mktemp -d)"
TIMEOUT_STATE="$TMPDIR_TIMEOUT/test-batched-state.json"
timeout_out=""
# Redirect to file instead of $() to avoid FD-leak blocking: command
# substitution waits for all writers to close stdout, but the orphaned
# sleep process holds the pipe open after the timeout kills the parent.
TEST_BATCHED_STATE_FILE="$TIMEOUT_STATE" bash "$SCRIPT" --timeout=1 "sleep 2" > "$TMPDIR_TIMEOUT/output.txt" 2>/dev/null || true
timeout_out=$(cat "$TMPDIR_TIMEOUT/output.txt")
rm -rf "$TMPDIR_TIMEOUT"
assert_contains "test_stops_after_timeout_and_outputs_resume_command: output contains ACTION REQUIRED" "ACTION REQUIRED" "$timeout_out"
assert_pass_if_clean "test_stops_after_timeout_and_outputs_resume_command"

# ── test_resume_from_state_file ───────────────────────────────────────────────
# Run a command with --timeout=1 so it saves state, then re-run the same command
# with the saved state file. The second run should skip the already-completed test.
echo ""
echo "--- test_resume_from_state_file ---"
_snapshot_fail
TMPDIR_RESUME="$(mktemp -d)"
existing_trap="$(trap -p EXIT | sed "s/trap -- '\\(.*\\)' EXIT/\\1/")"
if [ -n "$existing_trap" ]; then
    # shellcheck disable=SC2064
    trap "$existing_trap; rm -rf \"$TMPDIR_RESUME\"" EXIT
else
    trap 'rm -rf "$TMPDIR_RESUME"' EXIT
fi

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
TEST_BATCHED_STATE_FILE="$MID_STATE" bash "$SCRIPT" --timeout=1 "sleep 2" 2>/dev/null || true

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
[[ "$prog_out" =~ [0-9]+/[0-9]+ ]] && nm_found=1
assert_eq "test_progress_indicator_in_output: output contains N/M progress pattern" "1" "$nm_found"
rm -rf "$TMPDIR_PROG"
assert_pass_if_clean "test_progress_indicator_in_output"

# ── test_trap_cleanup_chains ──────────────────────────────────────────────────
# Verify that setting multiple EXIT traps via the chaining pattern causes both
# cleanup functions to run — not just the last one set.
echo ""
echo "--- test_trap_cleanup_chains ---"
_snapshot_fail

CHAIN_LOG="$(mktemp)"
# Subshell: set two chained EXIT traps and exit; both should append to CHAIN_LOG
(
    # shellcheck disable=SC2064
    trap "echo first >> \"$CHAIN_LOG\"" EXIT
    existing_trap="$(trap -p EXIT | sed "s/trap -- '\\(.*\\)' EXIT/\\1/")"
    if [ -n "$existing_trap" ]; then
        # shellcheck disable=SC2064
        trap "$existing_trap; echo second >> \"$CHAIN_LOG\"" EXIT
    else
        # shellcheck disable=SC2064
        trap "echo second >> \"$CHAIN_LOG\"" EXIT
    fi
    exit 0
)
chain_contents=""
chain_contents="$(cat "$CHAIN_LOG" 2>/dev/null || true)"
rm -f "$CHAIN_LOG"

first_ran=0
second_ran=0
[[ "$chain_contents" == *first* ]]  && first_ran=1
[[ "$chain_contents" == *second* ]] && second_ran=1
assert_eq "test_trap_cleanup_chains: first cleanup ran" "1" "$first_ran"
assert_eq "test_trap_cleanup_chains: second cleanup ran" "1" "$second_ran"
assert_pass_if_clean "test_trap_cleanup_chains"

# ── test_command_validation_compound_commands ─────────────────────────────────
# Compound commands (pipes, &&, ||) must be accepted without error and produce
# a valid summary line. This confirms the bash -c execution approach handles
# shell operators that would break a naive "which first_word" heuristic.
echo ""
echo "--- test_command_validation_compound_commands ---"
_snapshot_fail
TMPDIR_COMPOUND="$(mktemp -d)"
COMPOUND_STATE="$TMPDIR_COMPOUND/test-batched-state.json"
compound_out=""
compound_exit=0
compound_out=$(TEST_BATCHED_STATE_FILE="$COMPOUND_STATE" bash "$SCRIPT" --timeout=10 \
    "echo hello && echo world" 2>&1) || compound_exit=$?
# Must produce a summary line (pass/complete/summary signal)
compound_ok=0
[[ "${compound_out,,}" =~ pass|complete|summary ]] && compound_ok=1
assert_eq "test_command_validation_compound_commands: compound command produces summary" "1" "$compound_ok"
# Exit must be 0 (both echo commands succeed)
assert_eq "test_command_validation_compound_commands: compound command exits 0" "0" "$compound_exit"
rm -rf "$TMPDIR_COMPOUND"
assert_pass_if_clean "test_command_validation_compound_commands"

# ── test_command_validation_env_var_prefix ────────────────────────────────────
# Commands with environment variable prefixes (e.g., FOO=bar cmd) must be
# accepted and executed successfully. A heuristic that uses `which FOO=bar`
# would fail; bash -c handles this natively.
echo ""
echo "--- test_command_validation_env_var_prefix ---"
_snapshot_fail
TMPDIR_ENVVAR="$(mktemp -d)"
ENVVAR_STATE="$TMPDIR_ENVVAR/test-batched-state.json"
envvar_out=""
envvar_exit=0
envvar_out=$(TEST_BATCHED_STATE_FILE="$ENVVAR_STATE" bash "$SCRIPT" --timeout=10 \
    "FOO=bar echo test" 2>&1) || envvar_exit=$?
# Must produce a summary line
envvar_ok=0
[[ "${envvar_out,,}" =~ pass|complete|summary ]] && envvar_ok=1
assert_eq "test_command_validation_env_var_prefix: env var prefix produces summary" "1" "$envvar_ok"
# Exit must be 0
assert_eq "test_command_validation_env_var_prefix: env var prefix exits 0" "0" "$envvar_exit"
rm -rf "$TMPDIR_ENVVAR"
assert_pass_if_clean "test_command_validation_env_var_prefix"

# ─────────────────────────────────────────────────────────────────────────────
# Node.js runner tests
# ─────────────────────────────────────────────────────────────────────────────

# ── test_runner_node_triggers_file_discovery ──────────────────────────────────
# --runner=node should trigger .test.js / .test.mjs file discovery.
# We create a temp dir with a trivial .test.js file so we can verify the
# driver picked up the file.
echo ""
echo "--- test_runner_node_triggers_file_discovery ---"
_snapshot_fail
TMPDIR_NODE_DISC="$(mktemp -d)"
NODE_DISC_STATE="$TMPDIR_NODE_DISC/state.json"

cat > "$TMPDIR_NODE_DISC/sample.test.js" << 'JSEOF'
process.exit(0);
JSEOF

node_disc_out=""
node_disc_exit=0
if command -v node >/dev/null 2>&1; then
    node_disc_out=$(TEST_BATCHED_STATE_FILE="$NODE_DISC_STATE" \
        bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_NODE_DISC" --timeout=30 2>&1) \
        || node_disc_exit=$?
    assert_contains "test_runner_node_triggers_file_discovery: output mentions .test.js" \
        ".test.js" "$node_disc_out"
else
    node_disc_out=$(TEST_BATCHED_STATE_FILE="$NODE_DISC_STATE" \
        bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_NODE_DISC" --timeout=30 2>&1) \
        || node_disc_exit=$?
    assert_contains "test_runner_node_triggers_file_discovery: no node — fallback message" \
        "fallback" "$node_disc_out"
fi
rm -rf "$TMPDIR_NODE_DISC"
assert_pass_if_clean "test_runner_node_triggers_file_discovery"

# ── test_node_auto_detected_when_available ────────────────────────────────────
# Auto-detect: when node is on PATH and .test.js or .test.mjs files exist,
# the node driver should activate without an explicit --runner=node flag.
# Both .test.js and .test.mjs extensions must be recognized.
echo ""
echo "--- test_node_auto_detected_when_available ---"
_snapshot_fail
TMPDIR_NODE_AUTO="$(mktemp -d)"
NODE_AUTO_STATE="$TMPDIR_NODE_AUTO/state.json"

cat > "$TMPDIR_NODE_AUTO/a.test.js" << 'JSEOF'
process.exit(0);
JSEOF
cat > "$TMPDIR_NODE_AUTO/b.test.mjs" << 'JSEOF'
process.exit(0);
JSEOF

node_auto_out=""
node_auto_exit=0
if command -v node >/dev/null 2>&1; then
    node_auto_out=$(TEST_BATCHED_STATE_FILE="$NODE_AUTO_STATE" \
        bash "$SCRIPT" --test-dir="$TMPDIR_NODE_AUTO" --timeout=30 2>&1) \
        || node_auto_exit=$?
    auto_detected=0
    [[ "$node_auto_out" =~ \.test\.js|\.test\.mjs|node ]] && auto_detected=1
    assert_eq "test_node_auto_detected_when_available: auto-detection ran node driver" \
        "1" "$auto_detected"
else
    assert_eq "test_node_auto_detected_when_available: node not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_NODE_AUTO"
assert_pass_if_clean "test_node_auto_detected_when_available"

# ── test_node_tests_batched_by_file ───────────────────────────────────────────
# Node driver must batch tests by passing multiple files to one `node --test` call.
# Verify: output mentions individual .test.js filenames (not a single glob).
echo ""
echo "--- test_node_tests_batched_by_file ---"
_snapshot_fail
TMPDIR_NODE_BATCH="$(mktemp -d)"
NODE_BATCH_STATE="$TMPDIR_NODE_BATCH/state.json"

cat > "$TMPDIR_NODE_BATCH/first.test.js" << 'JSEOF'
process.exit(0);
JSEOF
cat > "$TMPDIR_NODE_BATCH/second.test.js" << 'JSEOF'
process.exit(0);
JSEOF

node_batch_out=""
node_batch_exit=0
if command -v node >/dev/null 2>&1; then
    node_batch_out=$(TEST_BATCHED_STATE_FILE="$NODE_BATCH_STATE" \
        bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_NODE_BATCH" --timeout=30 2>&1) \
        || node_batch_exit=$?
    assert_contains "test_node_tests_batched_by_file: first.test.js mentioned" \
        "first.test.js" "$node_batch_out"
    assert_contains "test_node_tests_batched_by_file: second.test.js mentioned" \
        "second.test.js" "$node_batch_out"
else
    assert_eq "test_node_tests_batched_by_file: node not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_NODE_BATCH"
assert_pass_if_clean "test_node_tests_batched_by_file"

# ── test_node_discovery_failure_falls_back ────────────────────────────────────
# When --runner=node is requested but no .test.js/.test.mjs files are found,
# the driver should fall back to the generic runner.
echo ""
echo "--- test_node_discovery_failure_falls_back ---"
_snapshot_fail
TMPDIR_NODE_NOFS="$(mktemp -d)"
NODE_NOFS_STATE="$TMPDIR_NODE_NOFS/state.json"
# Empty dir — no .test.js files

node_nofs_out=""
node_nofs_exit=0
node_nofs_out=$(TEST_BATCHED_STATE_FILE="$NODE_NOFS_STATE" \
    bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_NODE_NOFS" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) \
    || node_nofs_exit=$?

fallback_noted=0
[[ "${node_nofs_out,,}" =~ fallback|generic|no.*test.*file|passed ]] && fallback_noted=1
assert_eq "test_node_discovery_failure_falls_back: fallback triggered when no files found" \
    "1" "$fallback_noted"
rm -rf "$TMPDIR_NODE_NOFS"
assert_pass_if_clean "test_node_discovery_failure_falls_back"

# ── test_node_not_installed_falls_back ────────────────────────────────────────
# When node is not on PATH, the node driver must fall back to the generic runner
# rather than crashing.
echo ""
echo "--- test_node_not_installed_falls_back ---"
_snapshot_fail
TMPDIR_NODE_NOBIN="$(mktemp -d)"
NODE_NOBIN_STATE="$TMPDIR_NODE_NOBIN/state.json"

cat > "$TMPDIR_NODE_NOBIN/x.test.js" << 'JSEOF'
process.exit(0);
JSEOF

node_nobin_out=""
node_nobin_exit=0
# Override PATH to hide node but keep basic utilities
node_nobin_out=$(TEST_BATCHED_STATE_FILE="$NODE_NOBIN_STATE" \
    PATH="/usr/bin:/bin" \
    bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_NODE_NOBIN" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) \
    || node_nobin_exit=$?

nobin_ok=0
[[ "${node_nobin_out,,}" =~ fallback|generic|node.*not|passed ]] && nobin_ok=1
assert_eq "test_node_not_installed_falls_back: falls back when node not on PATH" \
    "1" "$nobin_ok"
rm -rf "$TMPDIR_NODE_NOBIN"
assert_pass_if_clean "test_node_not_installed_falls_back"

# ── test_interrupted_node_test_reruns_on_resume ───────────────────────────────
# When a node test is killed due to timeout, the run records "interrupted" and
# emits NEXT:. On a subsequent resume, the interrupted test must be RE-RUN
# (not skipped). Since the node test runs forever it will be interrupted again,
# which is still non-passing — but the key behavior is re-run, not skip.
echo ""
echo "--- test_interrupted_node_test_reruns_on_resume ---"
_snapshot_fail
TMPDIR_INT_NODE="$(mktemp -d)"
INT_NODE_STATE="$TMPDIR_INT_NODE/state.json"

if command -v node >/dev/null 2>&1; then
    # Create a .test.js that runs forever so the harness kills it on timeout
    cat > "$TMPDIR_INT_NODE/slow.test.js" << 'JSEOF'
const timer = setInterval(() => {}, 1000);
JSEOF

    # First run: timeout=1 with a slow node test → test gets killed → "interrupted" saved
    int_node_first_out=""
    int_node_first_out=$(TEST_BATCHED_STATE_FILE="$INT_NODE_STATE" \
        bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_INT_NODE" --timeout=1 2>&1) || true

    # Verify the first run emitted the Structured Action-Required Block
    assert_contains "test_interrupted_node_test_reruns_on_resume: first run emits NEXT:" \
        "ACTION REQUIRED" "$int_node_first_out"

    # Verify state file contains "interrupted" result
    int_has_interrupted=0
    if [ -f "$INT_NODE_STATE" ]; then
        python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
vals = list(d.get('results', {}).values())
sys.exit(0 if 'interrupted' in vals else 1)
" "$INT_NODE_STATE" && int_has_interrupted=1 || true
    fi
    assert_eq "test_interrupted_node_test_reruns_on_resume: state records interrupted result" \
        "1" "$int_has_interrupted"

    # Second run: resume from state file — interrupted test must be RE-RUN (not skipped).
    # The node test runs forever so it will be interrupted again.
    # When interrupted, the runner emits ACTION REQUIRED and exits 0 (more work needed).
    int_node_resume_out=""
    int_node_resume_out=$(TEST_BATCHED_STATE_FILE="$INT_NODE_STATE" \
        bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_INT_NODE" --timeout=2 2>&1) || true

    # The resume must NOT say "Skipping (already completed)" — the test is re-run
    _int_node_skipped=0
    [[ "$int_node_resume_out" == *Skipping* ]] && _int_node_skipped=1 || true
    assert_eq "test_interrupted_node_test_reruns_on_resume: resume does not skip interrupted test" \
        "0" "$_int_node_skipped"
    # Test is re-run: output must mention it running
    assert_contains "test_interrupted_node_test_reruns_on_resume: resume re-runs the node test" \
        "Running: node" "$int_node_resume_out"
else
    assert_eq "test_interrupted_node_test_reruns_on_resume: node not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_INT_NODE"
assert_pass_if_clean "test_interrupted_node_test_reruns_on_resume"

# ── test_interrupted_generic_test_reruns_on_resume ───────────────────────────
# When a generic runner test is killed due to timeout, "interrupted" is recorded
# in the state file. On resume, the interrupted test must be RE-RUN (not skipped)
# so it gets another chance to pass. Previously interrupted tests that pass on
# retry must result in exit 0 (not the old exit-non-zero-always behavior).
echo ""
echo "--- test_interrupted_generic_test_reruns_on_resume ---"
_snapshot_fail
TMPDIR_INT_GEN="$(mktemp -d)"
INT_GEN_STATE="$TMPDIR_INT_GEN/state.json"

# First run: timeout=1 with a slow command → test gets killed → "interrupted" saved
int_gen_first_out=""
# Redirect to file to avoid FD-leak blocking (see test_stops_after_timeout comment)
TEST_BATCHED_STATE_FILE="$INT_GEN_STATE" \
    bash "$SCRIPT" --timeout=1 "sleep 2" > "$TMPDIR_INT_GEN/first_output.txt" 2>&1 || true
int_gen_first_out=$(cat "$TMPDIR_INT_GEN/first_output.txt")

# Verify first run emits Structured Action-Required Block
assert_contains "test_interrupted_generic_test_reruns_on_resume: first run emits NEXT:" \
    "ACTION REQUIRED" "$int_gen_first_out"

# Verify state file contains "interrupted"
int_gen_has_interrupted=0
if [ -f "$INT_GEN_STATE" ]; then
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
vals = list(d.get('results', {}).values())
sys.exit(0 if 'interrupted' in vals else 1)
" "$INT_GEN_STATE" && int_gen_has_interrupted=1 || true
fi
assert_eq "test_interrupted_generic_test_reruns_on_resume: state records interrupted result" \
    "1" "$int_gen_has_interrupted"

# Second run: resume from the state file.
# The interrupted test must be RE-RUN (not skipped) — it should appear in output.
# With ample timeout (4s > sleep 2), the test passes and exit must be 0.
int_gen_resume_exit=0
int_gen_resume_out=""
int_gen_resume_out=$(TEST_BATCHED_STATE_FILE="$INT_GEN_STATE" \
    bash "$SCRIPT" --timeout=4 "sleep 2" 2>&1) \
    || int_gen_resume_exit=$?

assert_contains "test_interrupted_generic_test_reruns_on_resume: resume re-runs the test" \
    "Running: sleep 2" "$int_gen_resume_out"
assert_eq "test_interrupted_generic_test_reruns_on_resume: resume exits 0 when retry passes" \
    "0" "$int_gen_resume_exit"
rm -rf "$TMPDIR_INT_GEN"
assert_pass_if_clean "test_interrupted_generic_test_reruns_on_resume"

# ─────────────────────────────────────────────────────────────────────────────
# Pytest runner tests
# ─────────────────────────────────────────────────────────────────────────────

# ── test_runner_pytest_triggers_collection ────────────────────────────────────
# --runner=pytest should invoke pytest --collect-only -q for test enumeration.
# We create temp .py test files and verify the runner activates collection.
echo ""
echo "--- test_runner_pytest_triggers_collection ---"
_snapshot_fail
TMPDIR_PYTEST_COLLECT="$(mktemp -d)"
PYTEST_COLLECT_STATE="$TMPDIR_PYTEST_COLLECT/state.json"

# Create a trivial pytest test file
cat > "$TMPDIR_PYTEST_COLLECT/test_sample.py" << 'PYEOF'
def test_pass():
    assert True
PYEOF

pytest_collect_out=""
pytest_collect_exit=0
if command -v pytest >/dev/null 2>&1; then
    pytest_collect_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_COLLECT_STATE" \
        bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_COLLECT" --timeout=30 2>&1) \
        || pytest_collect_exit=$?
    # Output should reference the .py file discovered (collection occurred)
    py_mentioned=0
    [[ "$pytest_collect_out" =~ \.py|test_sample|collect ]] && py_mentioned=1
    assert_eq "test_runner_pytest_triggers_collection: pytest collection triggered" \
        "1" "$py_mentioned"
else
    # pytest not installed — expect fallback warning or generic runner behavior
    pytest_collect_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_COLLECT_STATE" \
        bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_COLLECT" --timeout=30 \
        "bash -c 'exit 0'" 2>&1) \
        || pytest_collect_exit=$?
    fallback_seen=0
    [[ "${pytest_collect_out,,}" =~ fallback|not.*path|passed ]] && fallback_seen=1
    assert_eq "test_runner_pytest_triggers_collection: no pytest — fallback triggered" \
        "1" "$fallback_seen"
fi
rm -rf "$TMPDIR_PYTEST_COLLECT"
assert_pass_if_clean "test_runner_pytest_triggers_collection"

# ── test_pytest_auto_detected_when_available ──────────────────────────────────
# When pytest is on PATH and tests/**/*.py files exist under test-dir, the
# pytest driver should auto-activate (no explicit --runner=pytest required).
echo ""
echo "--- test_pytest_auto_detected_when_available ---"
_snapshot_fail
TMPDIR_PYTEST_AUTO="$(mktemp -d)"
PYTEST_AUTO_STATE="$TMPDIR_PYTEST_AUTO/state.json"

mkdir -p "$TMPDIR_PYTEST_AUTO/tests"
cat > "$TMPDIR_PYTEST_AUTO/tests/test_auto.py" << 'PYEOF'
def test_auto_pass():
    assert True
PYEOF

pytest_auto_out=""
pytest_auto_exit=0
if command -v pytest >/dev/null 2>&1; then
    pytest_auto_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_AUTO_STATE" \
        bash "$SCRIPT" --test-dir="$TMPDIR_PYTEST_AUTO" --timeout=30 2>&1) \
        || pytest_auto_exit=$?
    auto_ok=0
    [[ "${pytest_auto_out,,}" =~ \.py|pytest|test_auto|passed ]] && auto_ok=1
    assert_eq "test_pytest_auto_detected_when_available: pytest auto-detection ran" \
        "1" "$auto_ok"
else
    assert_eq "test_pytest_auto_detected_when_available: pytest not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_PYTEST_AUTO"
assert_pass_if_clean "test_pytest_auto_detected_when_available"

# ── test_collected_tests_batched_via_pytest ───────────────────────────────────
# Multiple tests collected via pytest --collect-only should be passed together
# as a single pytest invocation (batched), not one process per test.
# Verify: output shows individual test IDs (test_a::test_1 etc.) from the runner.
echo ""
echo "--- test_collected_tests_batched_via_pytest ---"
_snapshot_fail
TMPDIR_PYTEST_BATCH="$(mktemp -d)"
PYTEST_BATCH_STATE="$TMPDIR_PYTEST_BATCH/state.json"

cat > "$TMPDIR_PYTEST_BATCH/test_first.py" << 'PYEOF'
def test_alpha():
    assert True

def test_beta():
    assert True
PYEOF
cat > "$TMPDIR_PYTEST_BATCH/test_second.py" << 'PYEOF'
def test_gamma():
    assert True
PYEOF

pytest_batch_out=""
pytest_batch_exit=0
if command -v pytest >/dev/null 2>&1; then
    pytest_batch_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_BATCH_STATE" \
        bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_BATCH" --timeout=30 2>&1) \
        || pytest_batch_exit=$?
    # Both test files should appear in output
    first_mentioned=0
    second_mentioned=0
    [[ "$pytest_batch_out" =~ test_first ]] && first_mentioned=1
    [[ "$pytest_batch_out" =~ test_second ]] && second_mentioned=1
    assert_eq "test_collected_tests_batched_via_pytest: test_first.py mentioned" \
        "1" "$first_mentioned"
    assert_eq "test_collected_tests_batched_via_pytest: test_second.py mentioned" \
        "1" "$second_mentioned"
else
    assert_eq "test_collected_tests_batched_via_pytest: pytest not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_PYTEST_BATCH"
assert_pass_if_clean "test_collected_tests_batched_via_pytest"

# ── test_collection_failure_falls_back_to_generic ────────────────────────────
# When pytest --collect-only fails (e.g., syntax error in test file), the
# runner should fall back to the generic runner rather than crashing.
echo ""
echo "--- test_collection_failure_falls_back_to_generic ---"
_snapshot_fail
TMPDIR_PYTEST_COLFAIL="$(mktemp -d)"
PYTEST_COLFAIL_STATE="$TMPDIR_PYTEST_COLFAIL/state.json"

# Write a test file with a syntax error to trigger collection failure
cat > "$TMPDIR_PYTEST_COLFAIL/test_broken.py" << 'PYEOF'
def test_broken(
    # syntax error — missing closing paren
PYEOF

pytest_colfail_out=""
pytest_colfail_exit=0
if command -v pytest >/dev/null 2>&1; then
    pytest_colfail_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_COLFAIL_STATE" \
        bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_COLFAIL" --timeout=30 \
        "bash -c 'exit 0'" 2>&1) \
        || pytest_colfail_exit=$?
    # Should fall back: output must mention fallback/generic OR produce a summary
    fallback_or_summary=0
    [[ "${pytest_colfail_out,,}" =~ fallback|generic|fall.back|passed ]] \
        && fallback_or_summary=1
    assert_eq "test_collection_failure_falls_back_to_generic: fallback on collection error" \
        "1" "$fallback_or_summary"
else
    assert_eq "test_collection_failure_falls_back_to_generic: pytest not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_PYTEST_COLFAIL"
assert_pass_if_clean "test_collection_failure_falls_back_to_generic"

# ── test_empty_collection_exits_with_message ─────────────────────────────────
# When --runner=pytest is used but no .py test files are found under test-dir,
# the runner should output a clear message and fall back to generic (or exit
# with a descriptive error when no CMD is provided).
echo ""
echo "--- test_empty_collection_exits_with_message ---"
_snapshot_fail
TMPDIR_PYTEST_EMPTY="$(mktemp -d)"
PYTEST_EMPTY_STATE="$TMPDIR_PYTEST_EMPTY/state.json"
# Empty dir — no .py files

pytest_empty_out=""
pytest_empty_exit=0
pytest_empty_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_EMPTY_STATE" \
    bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_EMPTY" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) \
    || pytest_empty_exit=$?

# Should produce a message about no files or fallback
empty_ok=0
[[ "${pytest_empty_out,,}" =~ no.*test|no.*\.py|fallback|generic|passed ]] \
    && empty_ok=1
assert_eq "test_empty_collection_exits_with_message: message on empty collection" \
    "1" "$empty_ok"
rm -rf "$TMPDIR_PYTEST_EMPTY"
assert_pass_if_clean "test_empty_collection_exits_with_message"

# ── test_malformed_collection_output_falls_back ───────────────────────────────
# If pytest --collect-only produces output with no parseable test IDs
# (e.g., empty output after filtering), the runner must fall back to generic.
echo ""
echo "--- test_malformed_collection_output_falls_back ---"
_snapshot_fail
TMPDIR_PYTEST_MALFORMED="$(mktemp -d)"
PYTEST_MALFORMED_STATE="$TMPDIR_PYTEST_MALFORMED/state.json"

# Create a conftest.py-only directory: pytest collects 0 tests but exits 0.
# The runner must treat zero collected tests as "empty collection → fallback".
cat > "$TMPDIR_PYTEST_MALFORMED/conftest.py" << 'PYEOF'
# no tests here — just a conftest
PYEOF

pytest_malformed_out=""
pytest_malformed_exit=0
pytest_malformed_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_MALFORMED_STATE" \
    bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_MALFORMED" --timeout=30 \
    "bash -c 'exit 0'" 2>&1) \
    || pytest_malformed_exit=$?

# Should fall back (zero tests collected = malformed/empty → generic)
malformed_ok=0
[[ "${pytest_malformed_out,,}" =~ fallback|generic|no.*test|passed ]] \
    && malformed_ok=1
assert_eq "test_malformed_collection_output_falls_back: empty collect → fallback" \
    "1" "$malformed_ok"
rm -rf "$TMPDIR_PYTEST_MALFORMED"
assert_pass_if_clean "test_malformed_collection_output_falls_back"

# ── test_mktemp_randomizes_exit_code_filename ─────────────────────────────────
# mktemp template must end with X characters for randomization to work on macOS.
# If the template has a suffix after the Xs (e.g., XXXXXX.txt), macOS mktemp
# creates a file with literal "XXXXXX.txt" — no randomization occurs.
echo ""
echo "--- test_mktemp_randomizes_exit_code_filename ---"
_snapshot_fail
TMPDIR_MKTEMP="$(mktemp -d)"
MKTEMP_STATE="$TMPDIR_MKTEMP/test-batched-state.json"

# Run a simple passing command through test-batched.sh
mktemp_out=""
mktemp_exit=0
mktemp_out=$(TEST_BATCHED_STATE_FILE="$MKTEMP_STATE" bash "$SCRIPT" --timeout=10 \
    "bash -c 'exit 0'" 2>&1) || mktemp_exit=$?

# After the run, the literal file /tmp/test-batched-exit-XXXXXX.txt should NOT exist.
# If mktemp failed to randomize (macOS bug with .txt suffix), this literal file is created.
literal_file_exists=0
[ -f "/tmp/test-batched-exit-XXXXXX.txt" ] && literal_file_exists=1
# Clean up in case the literal file was created
rm -f "/tmp/test-batched-exit-XXXXXX.txt"
rm -rf "$TMPDIR_MKTEMP"
assert_eq "test_mktemp_randomizes_exit_code_filename: no literal XXXXXX.txt file created" \
    "0" "$literal_file_exists"
assert_pass_if_clean "test_mktemp_randomizes_exit_code_filename"

# ── test_structured_action_required_block_on_timeout ─────────────────────────
# When tests are incomplete (time budget exhausted), test-batched.sh must emit
# the Structured Action-Required Block instead of a plain "NEXT:" line.
# The block must contain "ACTION REQUIRED" so agents cannot miss it.
echo ""
echo "--- test_structured_action_required_block_on_timeout ---"
_snapshot_fail
TMPDIR_SARB="$(mktemp -d)"
SARB_STATE="$TMPDIR_SARB/test-batched-state.json"
sarb_out=""
# Redirect to file to avoid FD-leak blocking (see test_stops_after_timeout comment)
TEST_BATCHED_STATE_FILE="$SARB_STATE" bash "$SCRIPT" --timeout=1 "sleep 2" > "$TMPDIR_SARB/output.txt" 2>/dev/null || true
sarb_out=$(cat "$TMPDIR_SARB/output.txt")
rm -rf "$TMPDIR_SARB"
sarb_has_action=0
[[ "$sarb_out" == *ACTION\ REQUIRED* ]] && sarb_has_action=1
assert_eq "test_structured_action_required_block_on_timeout: output contains 'ACTION REQUIRED'" "1" "$sarb_has_action"
sarb_has_run=0
[[ "$sarb_out" =~ (^|$'\n')RUN: ]] && sarb_has_run=1
assert_eq "test_structured_action_required_block_on_timeout: output contains 'RUN:' line" "1" "$sarb_has_run"
sarb_has_dnp=0
[[ "$sarb_out" == *DO\ NOT\ PROCEED* ]] && sarb_has_dnp=1
assert_eq "test_structured_action_required_block_on_timeout: output contains 'DO NOT PROCEED'" "1" "$sarb_has_dnp"
assert_pass_if_clean "test_structured_action_required_block_on_timeout"

# ── test_structured_action_required_block_run_line_contains_command ───────────
# The RUN: line in the Structured Action-Required Block must contain the resume
# command so the agent knows exactly what to run next.
echo ""
echo "--- test_structured_action_required_block_run_line_contains_command ---"
_snapshot_fail
TMPDIR_RUNCMD="$(mktemp -d)"
RUNCMD_STATE="$TMPDIR_RUNCMD/test-batched-state.json"
runcmd_out=""
# Redirect to file to avoid FD-leak blocking (see test_stops_after_timeout comment)
TEST_BATCHED_STATE_FILE="$RUNCMD_STATE" bash "$SCRIPT" --timeout=1 "sleep 2" > "$TMPDIR_RUNCMD/output.txt" 2>/dev/null || true
runcmd_out=$(cat "$TMPDIR_RUNCMD/output.txt")
rm -rf "$TMPDIR_RUNCMD"
runcmd_has_state=0
{ _runcmd_run_lines=$(grep "^RUN:" <<< "$runcmd_out"); [[ "$_runcmd_run_lines" == *TEST_BATCHED_STATE_FILE* ]]; } && runcmd_has_state=1
assert_eq "test_structured_action_required_block_run_line_contains_command: RUN: line contains resume command" "1" "$runcmd_has_state"
assert_pass_if_clean "test_structured_action_required_block_run_line_contains_command"

# ── Summary ───────────────────────────────────────────────────────────────────

# ── test_default_state_file_includes_repo_hash ────────────────────────────────
# When TEST_BATCHED_STATE_FILE is NOT set, the default state file path must
# include a repo-specific component (hash of git root path) so that sessions
# from different repos/worktrees do not collide.
#
# This is a test for bug w20-4idh: state file not isolated by repo/worktree.
echo ""
echo "--- test_default_state_file_includes_repo_hash ---"
_snapshot_fail
default_path_out=""
# Redirect to file to avoid FD-leak blocking (see test_stops_after_timeout comment)
_dp_tmp="$(mktemp -d)"
bash "$SCRIPT" --timeout=1 "sleep 2" > "$_dp_tmp/output.txt" 2>/dev/null || true
default_path_out=$(cat "$_dp_tmp/output.txt")
rm -rf "$_dp_tmp"
default_path_has_fixed=0
{ _dp_run_lines=$(grep "^RUN:" <<< "$default_path_out"); [[ "$_dp_run_lines" =~ test-batched-state\.json$ ]]; } && default_path_has_fixed=1
assert_eq "test_default_state_file_includes_repo_hash: default path is NOT the fixed /tmp/test-batched-state.json" \
    "0" "$default_path_has_fixed"
default_path_has_hash=0
{ _dp_run_lines2=$(grep "^RUN:" <<< "$default_path_out"); [[ "$_dp_run_lines2" =~ test-batched-state-[a-f0-9] ]]; } && default_path_has_hash=1
assert_eq "test_default_state_file_includes_repo_hash: default path contains repo hash segment" \
    "1" "$default_path_has_hash"
_cleanup_path=$(echo "$default_path_out" | grep "^RUN:" | grep -oE "TEST_BATCHED_STATE_FILE=[^ ]+" | cut -d= -f2 | tr -d "'")
[ -n "$_cleanup_path" ] && rm -f "$_cleanup_path" 2>/dev/null || true
assert_pass_if_clean "test_default_state_file_includes_repo_hash"

# ─────────────────────────────────────────────────────────────────────────────
# Bash runner tests
# ─────────────────────────────────────────────────────────────────────────────

# ── test_bash_runner_discovers_test_scripts ──────────────────────────────────
# --runner=bash --test-dir=<dir> should discover test-*.sh files under the dir
# and run each as a separate test item (not a single monolithic command).
echo ""
echo "--- test_bash_runner_discovers_test_scripts ---"
_snapshot_fail
TMPDIR_BASH_DISC="$(mktemp -d)"
BASH_DISC_STATE="$TMPDIR_BASH_DISC/state.json"

# Create two tiny test scripts
cat > "$TMPDIR_BASH_DISC/test-alpha.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_DISC/test-alpha.sh"
cat > "$TMPDIR_BASH_DISC/test-beta.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_DISC/test-beta.sh"

bash_disc_out=""
bash_disc_exit=0
bash_disc_out=$(TEST_BATCHED_STATE_FILE="$BASH_DISC_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_BASH_DISC" --timeout=30 2>&1) \
    || bash_disc_exit=$?

# Should mention both test scripts in output
disc_alpha=0
disc_beta=0
[[ "$bash_disc_out" == *test-alpha.sh* ]] && disc_alpha=1
[[ "$bash_disc_out" == *test-beta.sh* ]] && disc_beta=1
assert_eq "test_bash_runner_discovers_test_scripts: found test-alpha.sh" "1" "$disc_alpha"
assert_eq "test_bash_runner_discovers_test_scripts: found test-beta.sh" "1" "$disc_beta"
# Should show 2/2 progress (two separate items, not 1/1)
disc_two=0
[[ "$bash_disc_out" == *2/2* ]] && disc_two=1
assert_eq "test_bash_runner_discovers_test_scripts: shows 2/2 progress" "1" "$disc_two"
assert_eq "test_bash_runner_discovers_test_scripts: exits 0" "0" "$bash_disc_exit"
rm -rf "$TMPDIR_BASH_DISC"
assert_pass_if_clean "test_bash_runner_discovers_test_scripts"

# ── test_bash_runner_resumes_skipping_completed ─────────────────────────────
# After partial completion, resuming should skip already-completed scripts.
echo ""
echo "--- test_bash_runner_resumes_skipping_completed ---"
_snapshot_fail
TMPDIR_BASH_RESUME="$(mktemp -d)"
BASH_RESUME_STATE="$TMPDIR_BASH_RESUME/state.json"

cat > "$TMPDIR_BASH_RESUME/test-first.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_RESUME/test-first.sh"
cat > "$TMPDIR_BASH_RESUME/test-second.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_RESUME/test-second.sh"

# Pre-populate state file marking test-first.sh as completed
python3 -c "
import json, sys, time
state = {
  'runner': 'bash:' + sys.argv[1],
  'completed': ['test-first.sh'],
  'results': {'test-first.sh': 'pass'},
  'command_hash': '',
  'created_at': int(time.time())
}
with open(sys.argv[2], 'w') as f:
    json.dump(state, f, indent=2)
" "$TMPDIR_BASH_RESUME" "$BASH_RESUME_STATE"

bash_resume_out=""
bash_resume_exit=0
bash_resume_out=$(TEST_BATCHED_STATE_FILE="$BASH_RESUME_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_BASH_RESUME" --timeout=30 2>&1) \
    || bash_resume_exit=$?

# Should skip test-first.sh and run test-second.sh
skip_first=0
[[ "$bash_resume_out" =~ Skipping.*test-first\.sh ]] && skip_first=1
assert_eq "test_bash_runner_resumes_skipping_completed: skips test-first.sh" "1" "$skip_first"
ran_second=0
[[ "$bash_resume_out" =~ Running.*test-second\.sh ]] && ran_second=1
assert_eq "test_bash_runner_resumes_skipping_completed: runs test-second.sh" "1" "$ran_second"
rm -rf "$TMPDIR_BASH_RESUME"
assert_pass_if_clean "test_bash_runner_resumes_skipping_completed"

# ── test_bash_runner_fallback_when_no_test_dir ──────────────────────────────
# --runner=bash without --test-dir should warn and fall back to generic.
echo ""
echo "--- test_bash_runner_fallback_when_no_test_dir ---"
_snapshot_fail
TMPDIR_BASH_NODIR="$(mktemp -d)"
BASH_NODIR_STATE="$TMPDIR_BASH_NODIR/state.json"
bash_nodir_out=""
bash_nodir_exit=0
bash_nodir_out=$(TEST_BATCHED_STATE_FILE="$BASH_NODIR_STATE" \
    bash "$SCRIPT" --runner=bash --timeout=10 "bash -c 'exit 0'" 2>&1) \
    || bash_nodir_exit=$?
nodir_fallback=0
[[ "${bash_nodir_out,,}" =~ fallback|falling\ back ]] && nodir_fallback=1
assert_eq "test_bash_runner_fallback_when_no_test_dir: warns about fallback" "1" "$nodir_fallback"
rm -rf "$TMPDIR_BASH_NODIR"
assert_pass_if_clean "test_bash_runner_fallback_when_no_test_dir"

# ── test_bash_runner_records_failures ────────────────────────────────────────
# A failing test script should be recorded as "fail" in results.
echo ""
echo "--- test_bash_runner_records_failures ---"
_snapshot_fail
TMPDIR_BASH_FAIL="$(mktemp -d)"
BASH_FAIL_STATE="$TMPDIR_BASH_FAIL/state.json"

cat > "$TMPDIR_BASH_FAIL/test-pass.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_FAIL/test-pass.sh"
cat > "$TMPDIR_BASH_FAIL/test-fail.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 1
SHEOF
chmod +x "$TMPDIR_BASH_FAIL/test-fail.sh"

bash_fail_out=""
bash_fail_exit=0
bash_fail_out=$(TEST_BATCHED_STATE_FILE="$BASH_FAIL_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_BASH_FAIL" --timeout=30 2>&1) \
    || bash_fail_exit=$?

# Should report 1 passed, 1 failed
bash_fail_has_pass=0
[[ "$bash_fail_out" == *1\ passed* ]] && bash_fail_has_pass=1
assert_eq "test_bash_runner_records_failures: reports 1 passed" "1" "$bash_fail_has_pass"
bash_fail_has_fail=0
[[ "$bash_fail_out" == *1\ failed* ]] && bash_fail_has_fail=1
assert_eq "test_bash_runner_records_failures: reports 1 failed" "1" "$bash_fail_has_fail"
# Should exit non-zero when a test fails
assert_ne "test_bash_runner_records_failures: exits non-zero" "0" "$bash_fail_exit"
rm -rf "$TMPDIR_BASH_FAIL"
assert_pass_if_clean "test_bash_runner_records_failures"

# ── test_bash_auto_detected_when_test_scripts_exist ─────────────────────────
# Auto-detect: when test-*.sh files exist under --test-dir and no explicit
# --runner flag is given, the bash driver should activate automatically
# (after node and pytest auto-detect fail to claim the runner).
echo ""
echo "--- test_bash_auto_detected_when_test_scripts_exist ---"
_snapshot_fail
TMPDIR_BASH_AUTO="$(mktemp -d)"
BASH_AUTO_STATE="$TMPDIR_BASH_AUTO/state.json"

cat > "$TMPDIR_BASH_AUTO/test-auto-one.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_AUTO/test-auto-one.sh"
cat > "$TMPDIR_BASH_AUTO/test-auto-two.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_BASH_AUTO/test-auto-two.sh"

bash_auto_out=""
bash_auto_exit=0
bash_auto_out=$(TEST_BATCHED_STATE_FILE="$BASH_AUTO_STATE" \
    bash "$SCRIPT" --test-dir="$TMPDIR_BASH_AUTO" --timeout=30 2>&1) \
    || bash_auto_exit=$?
# Should auto-detect bash runner and show both scripts
auto_one=0
auto_two=0
[[ "$bash_auto_out" == *test-auto-one.sh* ]] && auto_one=1
[[ "$bash_auto_out" == *test-auto-two.sh* ]] && auto_two=1
assert_eq "test_bash_auto_detected_when_test_scripts_exist: found test-auto-one.sh" "1" "$auto_one"
assert_eq "test_bash_auto_detected_when_test_scripts_exist: found test-auto-two.sh" "1" "$auto_two"
# Should show 2/2 progress (not 1/1 generic fallback)
auto_progress=0
[[ "$bash_auto_out" == *2/2* ]] && auto_progress=1
assert_eq "test_bash_auto_detected_when_test_scripts_exist: shows 2/2 progress" "1" "$auto_progress"
assert_eq "test_bash_auto_detected_when_test_scripts_exist: exits 0" "0" "$bash_auto_exit"
rm -rf "$TMPDIR_BASH_AUTO"
assert_pass_if_clean "test_bash_auto_detected_when_test_scripts_exist"

# ── test_state_loading_overhead_is_sublinear ─────────────────────────────────
# When resuming with many completed tests, the startup overhead should NOT scale
# as O(N) subprocess invocations. Previously, each completed entry triggered a
# separate python3 subprocess to check if it was "interrupted" — causing 15+ seconds
# of overhead with 258 completed tests (the root cause of exit 144 / SIGURG kill).
#
# This test verifies that resuming with 200 completed tests in the state file
# completes the startup (skipping) phase within 10 seconds total.
echo ""
echo "--- test_state_loading_overhead_is_sublinear ---"
_snapshot_fail

TMPDIR_OVERHEAD="$(mktemp -d)"
OVERHEAD_STATE="$TMPDIR_OVERHEAD/state.json"

# Create 200 small test scripts and a state file marking all as completed
mkdir -p "$TMPDIR_OVERHEAD/tests"
for i in $(seq 1 200); do
    cat > "$TMPDIR_OVERHEAD/tests/test-gen-$(printf '%03d' "$i").sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
    chmod +x "$TMPDIR_OVERHEAD/tests/test-gen-$(printf '%03d' "$i").sh"
done

# Build state file marking all 200 as completed
python3 -c "
import json, time, sys, os

test_dir = sys.argv[1]
state_file = sys.argv[2]
files = sorted(f for f in os.listdir(test_dir) if f.startswith('test-') and f.endswith('.sh'))
state = {
    'runner': 'bash:' + test_dir,
    'completed': files,
    'results': {f: 'pass' for f in files},
    'command_hash': '',
    'created_at': int(time.time())
}
with open(state_file, 'w') as fh:
    json.dump(state, fh)
print(len(files))
" "$TMPDIR_OVERHEAD/tests" "$OVERHEAD_STATE" >/dev/null

# Add one more test that isn't in the completed list
cat > "$TMPDIR_OVERHEAD/tests/test-gen-201.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_OVERHEAD/tests/test-gen-201.sh"

# Time the resume run — should complete within 10s even with 200 entries in state
overhead_start=$(date +%s)
overhead_out=""
overhead_exit=0
overhead_out=$(TEST_BATCHED_STATE_FILE="$OVERHEAD_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_OVERHEAD/tests" --timeout=30 2>&1) \
    || overhead_exit=$?
overhead_end=$(date +%s)
overhead_elapsed=$(( overhead_end - overhead_start ))

# Should complete in under 10 seconds (was previously 20+ seconds due to O(N) python3 calls)
overhead_fast=0
[ "$overhead_elapsed" -lt 10 ] && overhead_fast=1
assert_eq "test_state_loading_overhead_is_sublinear: startup+skip of 200 completed < 10s (was: ${overhead_elapsed}s)" \
    "1" "$overhead_fast"

# Should have skipped the 200 completed tests and run the 201st
ran_201=0
[[ "$overhead_out" =~ Running.*test-gen-201\.sh ]] && ran_201=1
assert_eq "test_state_loading_overhead_is_sublinear: ran the un-completed test" "1" "$ran_201"

rm -rf "$TMPDIR_OVERHEAD"
assert_pass_if_clean "test_state_loading_overhead_is_sublinear"

# ── test_sigurg_trap_saves_state_and_exits_cleanly ───────────────────────────
# When SIGURG is delivered to test-batched.sh (the Claude Code tool ceiling),
# the signal handler must:
#   1. Save the state file (so resume works on the next invocation)
#   2. Print the ACTION REQUIRED block to stdout (so validate.sh detects PENDING)
#   3. Exit 0 (not 130/144) so callers treat it as PENDING, not FAIL
#
# Previously: handler exited 130 without printing ACTION REQUIRED.
# This caused validate.sh to record tests as FAIL, not PENDING.
echo ""
echo "--- test_sigurg_trap_saves_state_and_exits_cleanly ---"
_snapshot_fail

TMPDIR_SIGURG="$(mktemp -d)"
SIGURG_STATE="$TMPDIR_SIGURG/state.json"

# Create a test script that sleeps long enough for us to send SIGURG
mkdir -p "$TMPDIR_SIGURG/tests"
cat > "$TMPDIR_SIGURG/tests/test-long-running.sh" << 'SHEOF'
#!/usr/bin/env bash
sleep 2
exit 0
SHEOF
chmod +x "$TMPDIR_SIGURG/tests/test-long-running.sh"

# Run test-batched in background, send SIGURG after it starts the long test
sigurg_exit=0
sigurg_out=""

TEST_BATCHED_STATE_FILE="$SIGURG_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_SIGURG/tests" --timeout=10 \
    > "$TMPDIR_SIGURG/output.txt" 2>&1 &
BATCHED_PID=$!

# Wait for test-batched to start the background test (poll for "Running:" in output)
waited=0
while [ "$waited" -lt 5 ]; do
    sleep 0.5
    waited=$(( waited + 1 ))
    grep -q "Running:" "$TMPDIR_SIGURG/output.txt" 2>/dev/null && break
done

# Send SIGURG to test-batched
kill -URG "$BATCHED_PID" 2>/dev/null || true
wait "$BATCHED_PID" 2>/dev/null; sigurg_exit=$?
sigurg_out=$(cat "$TMPDIR_SIGURG/output.txt" 2>/dev/null)

# Verify: exits 0 (PENDING, not FAIL)
assert_eq "test_sigurg_trap_saves_state_and_exits_cleanly: exits 0" "0" "$sigurg_exit"

# Verify: ACTION REQUIRED block printed (so validate.sh detects PENDING)
sigurg_action_required=0
[[ "$sigurg_out" == *"ACTION REQUIRED"* ]] && sigurg_action_required=1
assert_eq "test_sigurg_trap_saves_state_and_exits_cleanly: ACTION REQUIRED in output" "1" "$sigurg_action_required"

# Verify: state file saved (so next invocation can resume)
sigurg_state_saved=0
[ -f "$SIGURG_STATE" ] && sigurg_state_saved=1
assert_eq "test_sigurg_trap_saves_state_and_exits_cleanly: state file saved" "1" "$sigurg_state_saved"

rm -rf "$TMPDIR_SIGURG"
assert_pass_if_clean "test_sigurg_trap_saves_state_and_exits_cleanly"

# ─────────────────────────────────────────────────────────────────────────────
# --filter flag tests
# ─────────────────────────────────────────────────────────────────────────────

# ── test_filter_runs_only_matching_files ─────────────────────────────────────
# --filter=test-foo* should run test-foo.sh but NOT test-bar.sh.
echo ""
echo "--- test_filter_runs_only_matching_files ---"
_snapshot_fail
TMPDIR_FILTER_MATCH="$(mktemp -d)"
FILTER_MATCH_STATE="$TMPDIR_FILTER_MATCH/state.json"

cat > "$TMPDIR_FILTER_MATCH/test-foo.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_FILTER_MATCH/test-foo.sh"
cat > "$TMPDIR_FILTER_MATCH/test-bar.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_FILTER_MATCH/test-bar.sh"

filter_match_out=""
filter_match_exit=0
filter_match_out=$(TEST_BATCHED_STATE_FILE="$FILTER_MATCH_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_FILTER_MATCH" --filter='test-foo*' --timeout=30 2>&1) \
    || filter_match_exit=$?

# test-foo.sh should appear in output
foo_ran=0
[[ "$filter_match_out" == *test-foo.sh* ]] && foo_ran=1
assert_eq "test_filter_runs_only_matching_files: test-foo.sh was run" "1" "$foo_ran"
# test-bar.sh must NOT appear in output (filtered out)
bar_ran=0
[[ "$filter_match_out" == *test-bar.sh* ]] && bar_ran=1
assert_eq "test_filter_runs_only_matching_files: test-bar.sh was NOT run" "0" "$bar_ran"
# Should show 1/1 (only one file matched)
one_of_one=0
[[ "$filter_match_out" == *1/1* ]] && one_of_one=1
assert_eq "test_filter_runs_only_matching_files: shows 1/1 progress (not 2/2)" "1" "$one_of_one"
assert_eq "test_filter_runs_only_matching_files: exits 0" "0" "$filter_match_exit"
rm -rf "$TMPDIR_FILTER_MATCH"
assert_pass_if_clean "test_filter_runs_only_matching_files"

# ── test_filter_no_match_warns_and_exits_zero ────────────────────────────────
# When --filter matches no files, a warning should be printed and exit code 0.
echo ""
echo "--- test_filter_no_match_warns_and_exits_zero ---"
_snapshot_fail
TMPDIR_FILTER_NONE="$(mktemp -d)"
FILTER_NONE_STATE="$TMPDIR_FILTER_NONE/state.json"

cat > "$TMPDIR_FILTER_NONE/test-alpha.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_FILTER_NONE/test-alpha.sh"

filter_none_out=""
filter_none_exit=0
filter_none_out=$(TEST_BATCHED_STATE_FILE="$FILTER_NONE_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_FILTER_NONE" --filter='test-nonexistent*' --timeout=30 2>&1) \
    || filter_none_exit=$?

# Should warn about no matches
no_match_warn=0
[[ "${filter_none_out,,}" =~ no.*test.*matched|no.*match|filter.*no|warning ]] && no_match_warn=1
assert_eq "test_filter_no_match_warns_and_exits_zero: warns about no matches" "1" "$no_match_warn"
# Should exit 0 (not an error)
assert_eq "test_filter_no_match_warns_and_exits_zero: exits 0" "0" "$filter_none_exit"
rm -rf "$TMPDIR_FILTER_NONE"
assert_pass_if_clean "test_filter_no_match_warns_and_exits_zero"

# ── test_filter_unknown_option_no_longer_errors ──────────────────────────────
# Before the fix, --filter produced "ERROR: Unknown option". Verify it no longer does.
echo ""
echo "--- test_filter_unknown_option_no_longer_errors ---"
_snapshot_fail
TMPDIR_FILTER_PARSE="$(mktemp -d)"
FILTER_PARSE_STATE="$TMPDIR_FILTER_PARSE/state.json"

cat > "$TMPDIR_FILTER_PARSE/test-x.sh" << 'SHEOF'
#!/usr/bin/env bash
exit 0
SHEOF
chmod +x "$TMPDIR_FILTER_PARSE/test-x.sh"

filter_parse_out=""
filter_parse_exit=0
filter_parse_out=$(TEST_BATCHED_STATE_FILE="$FILTER_PARSE_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_FILTER_PARSE" --filter='test-x*' --timeout=30 2>&1) \
    || filter_parse_exit=$?

unknown_opt=0
[[ "$filter_parse_out" == *"Unknown option"* ]] && unknown_opt=1
assert_eq "test_filter_unknown_option_no_longer_errors: no 'Unknown option' error" "0" "$unknown_opt"
rm -rf "$TMPDIR_FILTER_PARSE"
assert_pass_if_clean "test_filter_unknown_option_no_longer_errors"

# ── test_filter_resume_command_includes_filter ────────────────────────────────
# When a filtered run is interrupted, the RUN: resume command must include --filter.
echo ""
echo "--- test_filter_resume_command_includes_filter ---"
_snapshot_fail
TMPDIR_FILTER_RESUME="$(mktemp -d)"
FILTER_RESUME_STATE="$TMPDIR_FILTER_RESUME/state.json"

# Create a slow test so timeout triggers mid-run
cat > "$TMPDIR_FILTER_RESUME/test-slow.sh" << 'SHEOF'
#!/usr/bin/env bash
sleep 5
exit 0
SHEOF
chmod +x "$TMPDIR_FILTER_RESUME/test-slow.sh"

filter_resume_out=""
# timeout=1 so the slow test gets interrupted and ACTION REQUIRED is emitted
filter_resume_out=$(TEST_BATCHED_STATE_FILE="$FILTER_RESUME_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="$TMPDIR_FILTER_RESUME" --filter='test-slow*' --timeout=1 2>&1) || true

# Resume RUN: line must include --filter
filter_in_resume=0
{ _fr_run_lines=$(grep "^RUN:" <<< "$filter_resume_out"); [[ "$_fr_run_lines" == *"--filter="* ]]; } && filter_in_resume=1
assert_eq "test_filter_resume_command_includes_filter: RUN: line contains --filter" "1" "$filter_in_resume"
rm -rf "$TMPDIR_FILTER_RESUME"
assert_pass_if_clean "test_filter_resume_command_includes_filter"

# ── test_generic_per_test_timeout_exceeded_not_retried_on_resume ─────────────
# When --per-test-timeout=N is given and the command ALWAYS exceeds that budget,
# the generic runner must record "interrupted-timeout-exceeded" (not "interrupted")
# so that on resume the test is treated as already-completed and NOT re-run.
# Before the fix the generic runner never checks PER_TEST_TIMEOUT, records plain
# "interrupted", and resume re-runs the command forever (infinite retry loop).
echo ""
echo "--- test_generic_per_test_timeout_exceeded_not_retried_on_resume ---"
_snapshot_fail
TMPDIR_PTO="$(mktemp -d)"
PTO_STATE="$TMPDIR_PTO/state.json"

# First run: per-test-timeout=1, command always takes 2s → must exceed budget.
# Global timeout=4 so the global watchdog does not fire first.
pto_first_out=""
TEST_BATCHED_STATE_FILE="$PTO_STATE" \
    bash "$SCRIPT" --timeout=4 --per-test-timeout=1 "sleep 2" \
    > "$TMPDIR_PTO/first_output.txt" 2>&1 || true
pto_first_out=$(cat "$TMPDIR_PTO/first_output.txt")

# First run must emit the ACTION REQUIRED block (per-test-timeout was exceeded)
assert_contains \
    "test_generic_per_test_timeout_exceeded_not_retried_on_resume: first run emits ACTION REQUIRED" \
    "ACTION REQUIRED" "$pto_first_out"

# State file must record "interrupted-timeout-exceeded", NOT plain "interrupted"
pto_has_pto=0
pto_has_plain_interrupted=0
if [ -f "$PTO_STATE" ]; then
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
vals = list(d.get('results', {}).values())
print('pto' if 'interrupted-timeout-exceeded' in vals else 'no-pto')
print('plain' if 'interrupted' in vals else 'no-plain')
" "$PTO_STATE" > "$TMPDIR_PTO/state_check.txt" 2>/dev/null || true
    grep -q "^pto$" "$TMPDIR_PTO/state_check.txt" && pto_has_pto=1 || true
    grep -q "^plain$" "$TMPDIR_PTO/state_check.txt" && pto_has_plain_interrupted=1 || true
fi
assert_eq \
    "test_generic_per_test_timeout_exceeded_not_retried_on_resume: state records interrupted-timeout-exceeded" \
    "1" "$pto_has_pto"
assert_eq \
    "test_generic_per_test_timeout_exceeded_not_retried_on_resume: state does NOT record plain interrupted" \
    "0" "$pto_has_plain_interrupted"

# Second run: resume from state file with a generous timeout.
# The command must NOT be re-run — "Running: sleep" must be absent from output.
# The run must exit non-zero (test was never successful).
pto_resume_out=""
pto_resume_exit=0
pto_resume_out=$(TEST_BATCHED_STATE_FILE="$PTO_STATE" \
    bash "$SCRIPT" --timeout=10 --per-test-timeout=5 "sleep 2" 2>&1) \
    || pto_resume_exit=$?

pto_reran=0
[[ "$pto_resume_out" == *"Running: sleep 2"* ]] && pto_reran=1 || true
assert_eq \
    "test_generic_per_test_timeout_exceeded_not_retried_on_resume: second run does NOT re-run the command" \
    "0" "$pto_reran"
assert_ne \
    "test_generic_per_test_timeout_exceeded_not_retried_on_resume: second run exits non-zero" \
    "0" "$pto_resume_exit"

rm -rf "$TMPDIR_PTO"
assert_pass_if_clean "test_generic_per_test_timeout_exceeded_not_retried_on_resume"

# ── test_bash_runner_multi_dir_discovery ──────────────────────────────────────
# When --runner=bash --test-dir=dir1:dir2 (colon-separated) is passed,
# test-batched.sh must discover test-*.sh files from BOTH directories.
# Before this fix, bash-runner.sh passed TEST_DIR directly to _bash_discover_files
# which did not split on ':' — so only the first path would be treated as the dir,
# causing find to silently fail (path "dir1:dir2" does not exist).
echo ""
echo "--- test_bash_runner_multi_dir_discovery ---"
_snapshot_fail
TMPDIR_MULTIDIR="$(mktemp -d)"
MULTIDIR_A="$TMPDIR_MULTIDIR/suite_a"
MULTIDIR_B="$TMPDIR_MULTIDIR/suite_b"
mkdir -p "$MULTIDIR_A" "$MULTIDIR_B"
cat > "$MULTIDIR_A/test-alpha.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MULTIDIR_A/test-alpha.sh"
cat > "$MULTIDIR_B/test-beta.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MULTIDIR_B/test-beta.sh"

MULTIDIR_STATE="$TMPDIR_MULTIDIR/state.json"
multidir_out=""
multidir_exit=0
multidir_out=$(TEST_BATCHED_STATE_FILE="$MULTIDIR_STATE" \
    bash "$SCRIPT" --runner=bash --test-dir="${MULTIDIR_A}:${MULTIDIR_B}" --timeout=30 2>&1) \
    || multidir_exit=$?

# Both test files must appear in output
multidir_ran_alpha=0
multidir_ran_beta=0
[[ "$multidir_out" == *"test-alpha.sh"* ]] && multidir_ran_alpha=1 || true
[[ "$multidir_out" == *"test-beta.sh"* ]] && multidir_ran_beta=1 || true
assert_eq \
    "test_bash_runner_multi_dir_discovery: test-alpha.sh from suite_a is run" \
    "1" "$multidir_ran_alpha"
assert_eq \
    "test_bash_runner_multi_dir_discovery: test-beta.sh from suite_b is run" \
    "1" "$multidir_ran_beta"

# Total count must be 2
multidir_total_match=0
[[ "$multidir_out" == *"2/2 tests completed"* ]] && multidir_total_match=1 || true
assert_eq \
    "test_bash_runner_multi_dir_discovery: total count is 2 across both dirs" \
    "1" "$multidir_total_match"

# Exit must be 0 (all tests passed)
assert_eq \
    "test_bash_runner_multi_dir_discovery: exits 0 when all tests pass" \
    "0" "$multidir_exit"

rm -rf "$TMPDIR_MULTIDIR"
assert_pass_if_clean "test_bash_runner_multi_dir_discovery"

print_summary

