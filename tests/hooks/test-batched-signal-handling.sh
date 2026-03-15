#!/usr/bin/env bash
# Test SIGTERM/SIGINT signal handling in test-batched.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TEST_BATCHED="$REPO_ROOT/lockpick-workflow/scripts/test-batched.sh"

# Temporary directory for state files used in tests — isolated from other tests
WORK_DIR=$(mktemp -d)
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

print_summary
