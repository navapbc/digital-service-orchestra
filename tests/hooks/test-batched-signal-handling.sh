#!/usr/bin/env bash
# Test SIGTERM/SIGINT signal handling in test-batched.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
source "$SCRIPT_DIR/../lib/assert.sh"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TEST_BATCHED="$DSO_PLUGIN_DIR/scripts/test-batched.sh"

# Temporary directory for state files used in tests — isolated from other tests
WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064  # WORK_DIR intentionally expanded at trap-set time (value fixed here)
trap "rm -rf '$WORK_DIR'" EXIT

# ── Test 1: SIGTERM saves state and exits cleanly ──────────────────────────────
# Start test-batched.sh running a long-running command in the background,
# send SIGTERM after a short delay, then assert state was saved.

STATE_FILE="$WORK_DIR/signal-test-state.json"
rm -f "$STATE_FILE"

# Run test-batched with a long sleep and a long timeout so it won't stop on its own
TEST_BATCHED_STATE_FILE="$STATE_FILE" bash "$TEST_BATCHED" \
    --timeout=300 "sleep 60" &
BATCHED_PID=$!

# Give the script time to start running the command
sleep 2

# Send SIGTERM to the process
kill -TERM "$BATCHED_PID" 2>/dev/null || true

# Wait for the process to finish (it should exit quickly after signal)
wait "$BATCHED_PID" 2>/dev/null || true

# Assert that state file was created after signal
assert_ne "state_file_created_after_signal" "" "$([ -f "$STATE_FILE" ] && echo "exists" || echo "")"

# Assert the state file contains SIGNAL_INTERRUPTED marker
if [ -f "$STATE_FILE" ]; then
    state_content=$(cat "$STATE_FILE")
    assert_contains "state_has_signal_interrupted" "SIGNAL_INTERRUPTED" "$state_content"
else
    # File doesn't exist — force a failure
    assert_eq "state_file_must_exist" "exists" "missing"
fi

# ── Test 2: Resume after signal-interrupted state ──────────────────────────────
# Create a state file that looks like a signal-interrupted state.
# The script should detect it, log a resume message, and run from there.

STATE_FILE3="$WORK_DIR/resume-signal-state.json"

# Write a state file that simulates a prior signal-interrupted run.
# Use the generic runner ID format: command with special chars replaced
python3 -c "
import json
state = {
    'runner': 'true',
    'completed': ['true'],
    'results': {'true': 'pass'},
    'signal_interrupted': True,
    'SIGNAL_INTERRUPTED': True
}
with open('$STATE_FILE3', 'w') as f:
    json.dump(state, f, indent=2)
"

# Run with the same command as the completed test — it should see it's done and print summary
output=$(TEST_BATCHED_STATE_FILE="$STATE_FILE3" bash "$TEST_BATCHED" \
    --timeout=300 "true" 2>&1)

# Should show resuming message or completion summary
assert_contains "resume_or_complete" "completed" "$output"

# ── Test 3: Interrupted exit code is non-zero ──────────────────────────────────
# When interrupted by SIGTERM, test-batched should exit with a non-zero code.

STATE_FILE4="$WORK_DIR/exitcode-test-state.json"
rm -f "$STATE_FILE4"

TEST_BATCHED_STATE_FILE="$STATE_FILE4" bash "$TEST_BATCHED" \
    --timeout=300 "sleep 60" &
BATCHED_PID4=$!

sleep 2
kill -TERM "$BATCHED_PID4" 2>/dev/null || true
wait "$BATCHED_PID4" 2>/dev/null
SIGNAL_EXIT=$?

# Exit code should be non-zero (130 is standard for signal interruption)
assert_ne "signal_exit_is_nonzero" "0" "$SIGNAL_EXIT"

# ── Test 4: Child processes are killed when SIGTERM is sent ───────────────────
# Verify that when test-batched receives SIGTERM, it kills the child process
# it spawned (not just the parent). The child should not remain as an orphan.

STATE_FILE5="$WORK_DIR/child-kill-state.json"
CHILD_PID_FILE="$WORK_DIR/child-pid.txt"
rm -f "$STATE_FILE5" "$CHILD_PID_FILE"

# Run a command that writes its PID to a file, then sleeps
TEST_BATCHED_STATE_FILE="$STATE_FILE5" bash "$TEST_BATCHED" \
    --timeout=300 "echo \$\$ > '$CHILD_PID_FILE'; sleep 300" &
BATCHED_PID5=$!

# Wait until child_pid_file is written (up to 5 seconds)
_waited=0
while [ ! -f "$CHILD_PID_FILE" ] && [ "$_waited" -lt 50 ]; do
    sleep 0.1
    _waited=$(( _waited + 1 ))
done

CHILD_PID=""
if [ -f "$CHILD_PID_FILE" ]; then
    CHILD_PID=$(cat "$CHILD_PID_FILE" 2>/dev/null || true)
fi

# Send SIGTERM to test-batched
kill -TERM "$BATCHED_PID5" 2>/dev/null || true
wait "$BATCHED_PID5" 2>/dev/null || true

# Give a moment for cleanup
sleep 0.5

# Check if the child process (sleep 300) is still alive
child_alive=0
if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    child_alive=1
    # Clean up the orphan for test hygiene
    kill -KILL "$CHILD_PID" 2>/dev/null || true
fi

assert_eq "child_killed_on_sigterm" "0" "$child_alive"

# ── Test 5: SIGHUP saves state and exits non-zero ─────────────────────────────
# When a SIGHUP is received (e.g., terminal hangup or session close),
# test-batched should save state and exit with non-zero code (not 0).

STATE_FILE6="$WORK_DIR/sighup-test-state.json"
rm -f "$STATE_FILE6"

TEST_BATCHED_STATE_FILE="$STATE_FILE6" bash "$TEST_BATCHED" \
    --timeout=300 "sleep 60" &
BATCHED_PID6=$!

sleep 2

kill -HUP "$BATCHED_PID6" 2>/dev/null || true
wait "$BATCHED_PID6" 2>/dev/null
SIGHUP_EXIT=$?

assert_ne "sighup_state_file_created" "" "$([ -f "$STATE_FILE6" ] && echo "exists" || echo "")"
assert_ne "sighup_exit_is_nonzero" "0" "$SIGHUP_EXIT"

print_summary
