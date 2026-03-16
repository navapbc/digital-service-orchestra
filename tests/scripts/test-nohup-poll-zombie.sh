#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-nohup-poll-zombie.sh
# Tests for zombie detection and heartbeat-missing behavior in nohup-poll.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-nohup-poll-zombie.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

POLL_SCRIPT="$PLUGIN_ROOT/scripts/nohup-poll.sh"

echo "=== test-nohup-poll-zombie.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Helper: create a fake entry file ─────────────────────────────────────────
_make_entry() {
    local pid="$1" pid_dir="$2" output_file="$3"
    local exit_code_file="${output_file}.exitcode"
    mkdir -p "$pid_dir"
    cat > "$pid_dir/${pid}.entry" <<EOF
PID=$pid
COMMAND=test-command
OUTPUT_FILE=$output_file
LAUNCH_TIMESTAMP=2026-01-01T00:00:00Z
SESSION_ID=$$
EXIT_CODE_FILE=$exit_code_file
EOF
}

# ── Test: _is_zombie function exists in script ────────────────────────────────
echo ""
echo "--- _is_zombie helper defined ---"
_snapshot_fail

zombie_func_count=$(grep -c '_is_zombie' "$POLL_SCRIPT" 2>/dev/null || true)
assert_ne "_is_zombie function defined in nohup-poll.sh" "0" "$zombie_func_count"

assert_pass_if_clean "_is_zombie helper defined"

# ── Test: script contains zombie/defunct/state Z detection ───────────────────
echo ""
echo "--- zombie detection code present ---"
_snapshot_fail

zombie_code_count=$(grep -cE 'zombie|defunct|state.*Z|State.*Z' "$POLL_SCRIPT" 2>/dev/null || true)
assert_ne "zombie detection code present" "0" "$zombie_code_count"

assert_pass_if_clean "zombie detection code present"

# ── Test: cross-platform detection paths present ─────────────────────────────
echo ""
echo "--- cross-platform: /proc and ps paths ---"
_snapshot_fail

proc_path_count=$(grep -c '/proc/' "$POLL_SCRIPT" 2>/dev/null || true)
ps_state_count=$(grep -c 'ps.*state\|ps -o state\|state=.*-p' "$POLL_SCRIPT" 2>/dev/null || true)

assert_ne "Linux /proc path present" "0" "$proc_path_count"
assert_ne "macOS ps state= path present" "0" "$ps_state_count"

assert_pass_if_clean "cross-platform detection paths"

# ── Test: wait reaping attempt for zombie ────────────────────────────────────
echo ""
echo "--- wait reaping present ---"
_snapshot_fail

wait_reap_count=$(grep -cE 'wait.*PID|wait.*pid' "$POLL_SCRIPT" 2>/dev/null || true)
assert_ne "wait reaping for zombie" "0" "$wait_reap_count"

assert_pass_if_clean "wait reaping present"

# ── Test: completed:unknown reported for zombie (via mock) ───────────────────
#
# Strategy: We use a real zombie process. Create a subprocess that:
#   1. forks a child that immediately exits (becomes zombie)
#   2. keeps parent alive so zombie is not reaped
#
# Then point nohup-poll.sh at that zombie PID.
# This only works when /proc is available (Linux).
#
echo ""
echo "--- zombie process reports completed:unknown (Linux /proc) ---"
_snapshot_fail

if [[ -d /proc ]]; then
    # Create a zombie: a parent process that doesn't wait on a child that exits
    # The parent sleeps 10s; the child exits immediately → zombie
    bash -c '
        (exit 0) &              # child exits immediately — becomes zombie
        ZOMBIE_PID=$!
        # Write zombie PID to a file so the test can read it
        echo "$ZOMBIE_PID" > "'"$TMPDIR_TEST"'/zombie.pid"
        # Keep parent alive long enough for test; parent does NOT wait
        sleep 5
    ' &
    PARENT_PID=$!

    # Wait briefly for the child to exit and become zombie
    sleep 1

    ZOMBIE_PID=""
    if [[ -f "$TMPDIR_TEST/zombie.pid" ]]; then
        ZOMBIE_PID=$(cat "$TMPDIR_TEST/zombie.pid" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -n "$ZOMBIE_PID" ]] && [[ -d "/proc/$ZOMBIE_PID" ]]; then
        proc_state=$(awk '/^State:/{print $2}' "/proc/$ZOMBIE_PID/status" 2>/dev/null || true)
        if [[ "$proc_state" == "Z" ]]; then
            # PID is actually a zombie — run poll against it
            OUTPUT_FILE="$TMPDIR_TEST/zombie-test-output.txt"
            PID_DIR="$TMPDIR_TEST/pids-zombie"
            _make_entry "$ZOMBIE_PID" "$PID_DIR" "$OUTPUT_FILE"

            poll_output=$(NOHUP_PID_DIR="$PID_DIR" \
                bash "$POLL_SCRIPT" "$ZOMBIE_PID" 2>&1)

            assert_contains "zombie PID reports completed:unknown" "completed:unknown" "$poll_output"
        else
            # Process state is not Z — it may have already been reaped by the OS
            # This can happen on fast systems. Skip with a pass note.
            echo "SKIP: could not capture zombie state (state='$proc_state') — race condition"
            (( ++PASS ))
        fi
    else
        echo "SKIP: zombie PID unavailable (may have been reaped) — race condition"
        (( ++PASS ))
    fi

    # Clean up parent process
    kill "$PARENT_PID" 2>/dev/null || true
    wait "$PARENT_PID" 2>/dev/null || true
else
    echo "SKIP: /proc not available (non-Linux) — zombie /proc test skipped"
    (( ++PASS ))
fi

assert_pass_if_clean "zombie reports completed:unknown"

# ── Test: heartbeat-missing + old entry → stalled ────────────────────────────
#
# Create an entry where:
#   - Process PID is NOT alive (use a recycled/nonexistent PID)
#   - No heartbeat file exists
#   - Entry file is old enough (we fake age by setting NOHUP_STALL_THRESHOLD=0)
#
# But kill -0 will fail since the PID is gone, so we need a live PID with no heartbeat.
# Strategy: launch a real background process (sleep), then delete its heartbeat file,
# set a very low stall threshold, and poll. Process is alive but no heartbeat exists.
#
echo ""
echo "--- heartbeat missing + entry old → stalled ---"
_snapshot_fail

HB_OUTPUT_FILE="$TMPDIR_TEST/hb-test-output.txt"
HB_PID_DIR="$TMPDIR_TEST/pids-hb"

# Start a real long-running process
sleep 60 &
LIVE_PID=$!
trap 'kill '"$LIVE_PID"' 2>/dev/null || true; rm -rf "$TMPDIR_TEST"' EXIT

# Create entry for it (no heartbeat file, no exitcode file)
_make_entry "$LIVE_PID" "$HB_PID_DIR" "$HB_OUTPUT_FILE"

# Heartbeat file does NOT exist (never created — simulates crash-at-startup)
# Use threshold=0 so any age triggers stall
poll_output=$(NOHUP_PID_DIR="$HB_PID_DIR" NOHUP_STALL_THRESHOLD=0 \
    bash "$POLL_SCRIPT" "$LIVE_PID" 2>&1)

assert_contains "no-heartbeat + old entry reports stalled" "stalled" "$poll_output"

# Clean up live process
kill "$LIVE_PID" 2>/dev/null || true
wait "$LIVE_PID" 2>/dev/null || true

assert_pass_if_clean "heartbeat-missing reports stalled"

# ── Test: heartbeat-missing + recent entry → running (grace period) ───────────
#
# If heartbeat file is missing but entry is very fresh (< threshold), still running.
#
echo ""
echo "--- heartbeat missing + recent entry → running ---"
_snapshot_fail

HB2_OUTPUT_FILE="$TMPDIR_TEST/hb2-test-output.txt"
HB2_PID_DIR="$TMPDIR_TEST/pids-hb2"

# Start a real long-running process
sleep 60 &
LIVE_PID2=$!
trap 'kill '"$LIVE_PID2"' 2>/dev/null || true; kill '"$LIVE_PID"' 2>/dev/null || true; rm -rf "$TMPDIR_TEST"' EXIT

# Create entry for it (no heartbeat file, no exitcode file)
_make_entry "$LIVE_PID2" "$HB2_PID_DIR" "$HB2_OUTPUT_FILE"

# Use a large threshold — entry was just created, so should be within grace period
poll_output2=$(NOHUP_PID_DIR="$HB2_PID_DIR" NOHUP_STALL_THRESHOLD=9999 \
    bash "$POLL_SCRIPT" "$LIVE_PID2" 2>&1)

assert_contains "no-heartbeat + fresh entry reports running" "running" "$poll_output2"

# Clean up
kill "$LIVE_PID2" 2>/dev/null || true
wait "$LIVE_PID2" 2>/dev/null || true

assert_pass_if_clean "heartbeat-missing fresh entry running"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
