#!/usr/bin/env bash
# tests/scripts/test-validate-sigurg-handler.sh
# Tests that validate.sh traps SIGURG and exits 0 with ACTION REQUIRED block.
#
# Bug e2d5-1c9e: validate.sh exits 144 (SIGURG from Claude Code tool timeout)
# before test-batched.sh can complete. validate.sh lacks a SIGURG trap, so the
# default signal disposition terminates (Linux) or ignores (macOS) the signal
# rather than exiting cleanly with an ACTION REQUIRED block.
# test-batched.sh already handles SIGURG; validate.sh must do the same.
#
# Tests:
#   test_sigurg_exits_zero        -- validate.sh exits 0 (not non-zero) when SIGURG fires
#   test_sigurg_action_required   -- validate.sh emits ACTION REQUIRED block on SIGURG
#
# Usage: bash tests/scripts/test-validate-sigurg-handler.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-validate-sigurg-handler.sh ==="

TMPDIR_SIGURG="$(mktemp -d)"
_CLEANUP_PIDS=()
_cleanup() {
    for _p in "${_CLEANUP_PIDS[@]+"${_CLEANUP_PIDS[@]}"}"; do
        kill "$_p" 2>/dev/null || true
    done
    rm -rf "$TMPDIR_SIGURG"
}
trap _cleanup EXIT

# ── Stub: slow test-batched.sh so validate.sh stays blocked in wait ──────────
# All non-test checks in this repo complete in <1s (syntax=true, mypy=true, ruff fast).
# The test check (run_test_check) is the only one that can be made slow.
# Set VALIDATE_TEST_STATE_FILE to a fresh temp path to bypass session cache,
# then inject a slow test-batched.sh stub so validate.sh blocks in `wait`.
STUB_TEST_BATCHED="$TMPDIR_SIGURG/test-batched.sh"
cat > "$STUB_TEST_BATCHED" << 'TBSTUB'
#!/usr/bin/env bash
# Slow stub: blocks so validate.sh stays in `wait` phase for SIGURG test
sleep 60
TBSTUB
chmod +x "$STUB_TEST_BATCHED"

FRESH_STATE_FILE="$TMPDIR_SIGURG/fresh-test-state.json"

# ── Run validate.sh in background ────────────────────────────────────────────
OUTPUT_FILE="$TMPDIR_SIGURG/validate-out.txt"
sigurg_exit=255

VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    VALIDATE_TEST_STATE_FILE="$FRESH_STATE_FILE" \
    TEST_BATCHED_STATE_FILE="$FRESH_STATE_FILE" \
    VALIDATE_SKIP_PLUGIN_CHECKS=1 \
    bash "$VALIDATE_SH" >"$OUTPUT_FILE" 2>&1 &
VALIDATE_PID=$!
_CLEANUP_PIDS+=("$VALIDATE_PID")

# Wait up to 6s for validate.sh to launch background checks and enter `wait`.
# Non-test checks (syntax=true, mypy=true, ruff) complete in <1s.
# After they finish, validate.sh is stuck in `wait` for the test-batched stub.
waited=0
while [ "$waited" -lt 12 ]; do
    sleep 0.5
    waited=$(( waited + 1 ))
    kill -0 "$VALIDATE_PID" 2>/dev/null || break
done

# Send SIGURG — simulates Claude Code tool timeout
kill -URG "$VALIDATE_PID" 2>/dev/null || true

# Kill timer: if SIGURG is ignored (macOS default without a trap), validate.sh
# won't exit on its own. After 3s, forcefully kill it so the test doesn't hang.
# With the fix (SIGURG trap), validate.sh exits 0 within milliseconds of SIGURG.
# Without the fix, the kill timer fires, validate.sh is killed with SIGTERM (exit 143).
( sleep 3 && kill "$VALIDATE_PID" 2>/dev/null ) &
_kill_timer=$!
_CLEANUP_PIDS+=("$_kill_timer")

wait "$VALIDATE_PID" 2>/dev/null; sigurg_exit=$?
kill "$_kill_timer" 2>/dev/null || true
wait "$_kill_timer" 2>/dev/null || true

validate_out=$(cat "$OUTPUT_FILE" 2>/dev/null || echo "")

# ── Test 1: exits 0 ───────────────────────────────────────────────────────────
echo "Test 1: validate.sh exits 0 when SIGURG fires (not killed/non-zero)"
if [ "$sigurg_exit" -eq 0 ]; then
    echo "  PASS: exits 0"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0, got $sigurg_exit" >&2
    echo "        Fix: add trap _sigurg_handler SIGURG in validate.sh, handler must exit 0" >&2
    (( FAIL++ ))
fi

# ── Test 2: ACTION REQUIRED in output ────────────────────────────────────────
echo "Test 2: validate.sh emits ACTION REQUIRED block on SIGURG"
if [[ "$validate_out" == *"ACTION REQUIRED"* ]]; then
    echo "  PASS: ACTION REQUIRED in output"
    (( PASS++ ))
else
    echo "  FAIL: ACTION REQUIRED not found in output" >&2
    echo "        Fix: SIGURG handler must print ACTION REQUIRED block before exiting" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
