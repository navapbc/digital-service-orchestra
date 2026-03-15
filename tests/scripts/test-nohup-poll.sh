#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-nohup-poll.sh
# Tests for lockpick-workflow/scripts/nohup-poll.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-nohup-poll.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

POLL_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/nohup-poll.sh"
LAUNCH_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/nohup-launch.sh"

echo "=== test-nohup-poll.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Test: script exists and is executable ────────────────────────────────────
echo ""
echo "--- existence and permissions ---"
_snapshot_fail

if [[ -x "$POLL_SCRIPT" ]]; then
    (( ++PASS ))
    echo "script is executable ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: $POLL_SCRIPT is not executable"
fi

assert_pass_if_clean "script exists and is executable"

# ── Test: reports status keywords ────────────────────────────────────────────
echo ""
echo "--- status keywords present ---"
_snapshot_fail

poll_content=$(cat "$POLL_SCRIPT")
has_running=$(echo "$poll_content" | grep -c 'running' || true)
has_completed=$(echo "$poll_content" | grep -c 'completed' || true)
has_not_found=$(echo "$poll_content" | grep -c 'not.found\|not_found\|NOT_FOUND' || true)

assert_ne "contains 'running' status" "0" "$has_running"
assert_ne "contains 'completed' status" "0" "$has_completed"
assert_ne "contains 'not found' status" "0" "$has_not_found"

assert_pass_if_clean "status keywords present"

# ── Test: not found for bogus PID ────────────────────────────────────────────
echo ""
echo "--- not found for bogus PID ---"
_snapshot_fail

poll_output=$(NOHUP_PID_DIR="$TMPDIR_TEST/pids-empty" \
    bash "$POLL_SCRIPT" 99999 2>&1)
poll_exit=$?

assert_contains "reports not found" "not" "$(echo "$poll_output" | tr '[:upper:]' '[:lower:]')"

assert_pass_if_clean "not found for bogus PID"

# ── Test: completed task ─────────────────────────────────────────────────────
echo ""
echo "--- completed task ---"
_snapshot_fail

OUTPUT_FILE="$TMPDIR_TEST/poll-test-output.txt"
PID_DIR="$TMPDIR_TEST/pids-poll"

# Launch a fast-completing task
NOHUP_PROCESS_BUDGET=99999 \
NOHUP_PID_DIR="$PID_DIR" \
    bash "$LAUNCH_SCRIPT" "$OUTPUT_FILE" -- echo "poll-marker" 2>/dev/null
launch_exit=$?

assert_eq "launch succeeds" "0" "$launch_exit"

# Wait for task to complete
sleep 1

# Get the PID from the entry file
if ls "$PID_DIR"/*.entry >/dev/null 2>&1; then
    entry_file=$(ls "$PID_DIR"/*.entry | head -1)
    pid=$(basename "$entry_file" .entry)

    poll_output=$(NOHUP_PID_DIR="$PID_DIR" \
        bash "$POLL_SCRIPT" "$pid" 2>&1)

    assert_contains "reports completed" "completed" "$(echo "$poll_output" | tr '[:upper:]' '[:lower:]')"
else
    (( ++FAIL ))
    echo "FAIL: no entry files found after launch"
fi

assert_pass_if_clean "completed task"

# ── Test: no arguments shows usage ──────────────────────────────────────────
echo ""
echo "--- usage message ---"
_snapshot_fail

usage_output=$(bash "$POLL_SCRIPT" 2>&1 || true)
assert_contains "shows usage on no args" "usage" "$(echo "$usage_output" | tr '[:upper:]' '[:lower:]')"

assert_pass_if_clean "usage message"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
