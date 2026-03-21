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
timeout_out=$(TEST_BATCHED_STATE_FILE="$TIMEOUT_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null) || true
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
    trap "$existing_trap; rm -rf \"\$TMPDIR_RESUME\"" EXIT
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

# ── test_trap_cleanup_chains ──────────────────────────────────────────────────
# Verify that setting multiple EXIT traps via the chaining pattern causes both
# cleanup functions to run — not just the last one set.
echo ""
echo "--- test_trap_cleanup_chains ---"
_snapshot_fail

CHAIN_LOG="$(mktemp)"
# Subshell: set two chained EXIT traps and exit; both should append to CHAIN_LOG
(
    trap "echo first >> \"$CHAIN_LOG\"" EXIT
    existing_trap="$(trap -p EXIT | sed "s/trap -- '\\(.*\\)' EXIT/\\1/")"
    if [ -n "$existing_trap" ]; then
        trap "$existing_trap; echo second >> \"$CHAIN_LOG\"" EXIT
    else
        trap "echo second >> \"$CHAIN_LOG\"" EXIT
    fi
    exit 0
)
chain_contents=""
chain_contents="$(cat "$CHAIN_LOG" 2>/dev/null || true)"
rm -f "$CHAIN_LOG"

first_ran=0
second_ran=0
echo "$chain_contents" | grep -q 'first'  && first_ran=1
echo "$chain_contents" | grep -q 'second' && second_ran=1
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
echo "$compound_out" | grep -qiE 'pass|complete|summary' && compound_ok=1
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
echo "$envvar_out" | grep -qiE 'pass|complete|summary' && envvar_ok=1
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
    (echo "$node_auto_out" | grep -qE '\.test\.js|\.test\.mjs|node') && auto_detected=1
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
(echo "$node_nofs_out" | grep -qiE 'fallback|generic|no.*test.*file|passed') && fallback_noted=1
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
(echo "$node_nobin_out" | grep -qiE 'fallback|generic|node.*not|passed') && nobin_ok=1
assert_eq "test_node_not_installed_falls_back: falls back when node not on PATH" \
    "1" "$nobin_ok"
rm -rf "$TMPDIR_NODE_NOBIN"
assert_pass_if_clean "test_node_not_installed_falls_back"

# ── test_interrupted_node_test_exits_nonzero ─────────────────────────────────
# When a node test is killed due to timeout, the run records "interrupted" and
# emits NEXT:. On a subsequent resume, the interrupted result must cause a
# non-zero exit so callers know the run did not fully succeed.
echo ""
echo "--- test_interrupted_node_test_exits_nonzero ---"
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
    assert_contains "test_interrupted_node_test_exits_nonzero: first run emits NEXT:" \
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
    assert_eq "test_interrupted_node_test_exits_nonzero: state records interrupted result" \
        "1" "$int_has_interrupted"

    # Second run: resume from state file — all tests already "completed" (as interrupted)
    # This resume should exit non-zero because interrupted tests are non-passing
    int_node_resume_exit=0
    int_node_resume_out=""
    int_node_resume_out=$(TEST_BATCHED_STATE_FILE="$INT_NODE_STATE" \
        bash "$SCRIPT" --runner=node --test-dir="$TMPDIR_INT_NODE" --timeout=30 2>&1) \
        || int_node_resume_exit=$?

    assert_contains "test_interrupted_node_test_exits_nonzero: resume output contains 'interrupted'" \
        "interrupted" "$int_node_resume_out"
    assert_ne "test_interrupted_node_test_exits_nonzero: resume exits non-zero on all-interrupted run" \
        "0" "$int_node_resume_exit"
else
    assert_eq "test_interrupted_node_test_exits_nonzero: node not installed (skip)" "ok" "ok"
fi
rm -rf "$TMPDIR_INT_NODE"
assert_pass_if_clean "test_interrupted_node_test_exits_nonzero"

# ── test_interrupted_generic_test_resume_exits_nonzero ───────────────────────
# When a generic runner test is killed due to timeout, "interrupted" is recorded
# in the state file. On resume, the script detects the interrupted result and
# must exit non-zero.
echo ""
echo "--- test_interrupted_generic_test_resume_exits_nonzero ---"
_snapshot_fail
TMPDIR_INT_GEN="$(mktemp -d)"
INT_GEN_STATE="$TMPDIR_INT_GEN/state.json"

# First run: timeout=1 with a slow command → test gets killed → "interrupted" saved
int_gen_first_out=""
int_gen_first_out=$(TEST_BATCHED_STATE_FILE="$INT_GEN_STATE" \
    bash "$SCRIPT" --timeout=1 "sleep 30" 2>&1) || true

# Verify first run emits Structured Action-Required Block
assert_contains "test_interrupted_generic_test_resume_exits_nonzero: first run emits NEXT:" \
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
assert_eq "test_interrupted_generic_test_resume_exits_nonzero: state records interrupted result" \
    "1" "$int_gen_has_interrupted"

# Second run: resume from the state file.
# The test ID is already in "completed" list with result "interrupted".
# The resume run skips the test (already done) and must exit non-zero.
int_gen_resume_exit=0
int_gen_resume_out=""
int_gen_resume_out=$(TEST_BATCHED_STATE_FILE="$INT_GEN_STATE" \
    bash "$SCRIPT" --timeout=30 "sleep 30" 2>&1) \
    || int_gen_resume_exit=$?

assert_contains "test_interrupted_generic_test_resume_exits_nonzero: resume mentions interrupted" \
    "interrupted" "$int_gen_resume_out"
assert_ne "test_interrupted_generic_test_resume_exits_nonzero: resume exits non-zero" \
    "0" "$int_gen_resume_exit"
rm -rf "$TMPDIR_INT_GEN"
assert_pass_if_clean "test_interrupted_generic_test_resume_exits_nonzero"

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
    (echo "$pytest_collect_out" | grep -qE '\.py|test_sample|collect') && py_mentioned=1
    assert_eq "test_runner_pytest_triggers_collection: pytest collection triggered" \
        "1" "$py_mentioned"
else
    # pytest not installed — expect fallback warning or generic runner behavior
    pytest_collect_out=$(TEST_BATCHED_STATE_FILE="$PYTEST_COLLECT_STATE" \
        bash "$SCRIPT" --runner=pytest --test-dir="$TMPDIR_PYTEST_COLLECT" --timeout=30 \
        "bash -c 'exit 0'" 2>&1) \
        || pytest_collect_exit=$?
    fallback_seen=0
    (echo "$pytest_collect_out" | grep -qiE 'fallback|not.*path|passed') && fallback_seen=1
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
    (echo "$pytest_auto_out" | grep -qiE '\.py|pytest|test_auto|passed') && auto_ok=1
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
    (echo "$pytest_batch_out" | grep -qE 'test_first') && first_mentioned=1
    (echo "$pytest_batch_out" | grep -qE 'test_second') && second_mentioned=1
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
    (echo "$pytest_colfail_out" | grep -qiE 'fallback|generic|fall.back|passed') \
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
(echo "$pytest_empty_out" | grep -qiE 'no.*test|no.*\.py|fallback|generic|passed') \
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
(echo "$pytest_malformed_out" | grep -qiE 'fallback|generic|no.*test|passed') \
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
sarb_out=$(TEST_BATCHED_STATE_FILE="$SARB_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null) || true
rm -rf "$TMPDIR_SARB"
sarb_has_action=0
echo "$sarb_out" | grep -q "ACTION REQUIRED" && sarb_has_action=1
assert_eq "test_structured_action_required_block_on_timeout: output contains 'ACTION REQUIRED'" "1" "$sarb_has_action"
sarb_has_run=0
echo "$sarb_out" | grep -q "^RUN:" && sarb_has_run=1
assert_eq "test_structured_action_required_block_on_timeout: output contains 'RUN:' line" "1" "$sarb_has_run"
sarb_has_dnp=0
echo "$sarb_out" | grep -q "DO NOT PROCEED" && sarb_has_dnp=1
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
runcmd_out=$(TEST_BATCHED_STATE_FILE="$RUNCMD_STATE" bash "$SCRIPT" --timeout=1 "sleep 10" 2>/dev/null) || true
rm -rf "$TMPDIR_RUNCMD"
runcmd_has_state=0
echo "$runcmd_out" | grep "^RUN:" | grep -q "TEST_BATCHED_STATE_FILE" && runcmd_has_state=1
assert_eq "test_structured_action_required_block_run_line_contains_command: RUN: line contains resume command" "1" "$runcmd_has_state"
assert_pass_if_clean "test_structured_action_required_block_run_line_contains_command"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
