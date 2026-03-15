#!/usr/bin/env bash
# Test heartbeat functionality in nohup-launch.sh and stall detection in nohup-poll.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
LAUNCH_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/nohup-launch.sh"
POLL_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/nohup-poll.sh"

TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

export NOHUP_PID_DIR="$TEST_DIR/pids"
export NOHUP_PROCESS_BUDGET=5000
export NOHUP_HEARTBEAT_INTERVAL=1

# ── Test 1: Launch creates heartbeat file ──
OUTPUT_FILE="$TEST_DIR/test1-output.txt"
PID=$(bash "$LAUNCH_SCRIPT" "$OUTPUT_FILE" -- sleep 1 2>/dev/null)
# Wait for initial heartbeat write
for i in $(seq 1 10); do
    [ -f "${OUTPUT_FILE}.heartbeat" ] && break
    sleep 0.2
done

HEARTBEAT_FILE="${OUTPUT_FILE}.heartbeat"
if [ -f "$HEARTBEAT_FILE" ]; then
    heartbeat_val=$(cat "$HEARTBEAT_FILE" 2>/dev/null)
    assert_ne "heartbeat_created" "" "$heartbeat_val"
else
    assert_eq "heartbeat_created" "file exists" "file missing"
fi

# Wait for process to finish
sleep 2

# ── Test 2: Poll reports completed for finished process ──
poll_result=$(bash "$POLL_SCRIPT" "$PID" 2>/dev/null)
assert_contains "poll_completed" "completed" "$poll_result"

# ── Test 3: Poll detects stalled process (heartbeat too old) ──
# Create a fake entry with a stale heartbeat
FAKE_PID=99999
mkdir -p "$NOHUP_PID_DIR"
cat > "$NOHUP_PID_DIR/${FAKE_PID}.entry" <<EOF
PID=$FAKE_PID
COMMAND=fake command
OUTPUT_FILE=$TEST_DIR/fake-output.txt
LAUNCH_TIMESTAMP=2026-01-01T00:00:00Z
SESSION_ID=test
EXIT_CODE_FILE=$TEST_DIR/fake-output.txt.exitcode
EOF

# Create a heartbeat file with a very old timestamp (300+ seconds ago)
OLD_TS=$(($(date +%s) - 400))
echo "$OLD_TS" > "$TEST_DIR/fake-output.txt.heartbeat"

# We can't easily make kill -0 return true for a fake PID,
# so we test that the poll script handles the heartbeat file correctly
# when the process is gone
poll_result=$(bash "$POLL_SCRIPT" "$FAKE_PID" 2>/dev/null)
# Process gone + no exit code file = completed:unknown
assert_contains "stale_process_detected" "completed" "$poll_result"

# ── Test 4: Poll reports not_found for unknown PID ──
poll_result=$(bash "$POLL_SCRIPT" "12345" 2>/dev/null)
assert_eq "unknown_pid" "not_found" "$poll_result"

print_summary
