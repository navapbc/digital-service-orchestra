#!/usr/bin/env bash
# tests/scripts/test-retro-gather.sh
# Baseline tests for scripts/retro-gather.sh
#
# Usage: bash tests/scripts/test-retro-gather.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/retro-gather.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-retro-gather.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ─────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 3: Script requires git repo ─────────────────────────────────────────
echo "Test 3: Script exits non-zero when not in a git repo"
exit_code=0
TMP_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_DIR")
( cd "$TMP_DIR" && bash "$SCRIPT" 2>/dev/null ) || exit_code=$?
rmdir "$TMP_DIR" 2>/dev/null || true
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero outside git repo (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit outside git repo" >&2
    (( FAIL++ ))
fi

# ── Test 4: Output contains === section headers ───────────────────────────────
# retro-gather.sh calls validate.sh which can hang waiting for CI.
# Use a background process with a kill-timer to prevent infinite hangs.
echo "Test 4: Output contains === section headers"
_OUTFILE=$(mktemp)
_CLEANUP_DIRS+=("$_OUTFILE")
bash "$SCRIPT" --quick >"$_OUTFILE" 2>&1 &
_PID=$!
# Timeout is injectable via RETRO_GATHER_TEST_TIMEOUT (default: 15s).
# Set to a small value (e.g. 1) in CI or fast test runs.
_TIMEOUT="${RETRO_GATHER_TEST_TIMEOUT:-15}"
( sleep "$_TIMEOUT" && kill "$_PID" 2>/dev/null ) &
_TIMER=$!
wait "$_PID" 2>/dev/null || true
kill "$_TIMER" 2>/dev/null; wait "$_TIMER" 2>/dev/null || true
output=$(cat "$_OUTFILE")
rm -f "$_OUTFILE"
if echo "$output" | grep -qE "=== [A-Z]"; then
    echo "  PASS: output contains section headers"
    (( PASS++ ))
else
    echo "  FAIL: output missing section headers" >&2
    (( FAIL++ ))
fi

# ── Test 5: --quick flag produces CLEANUP section ────────────────────────────
echo "Test 5: --quick flag produces CLEANUP section"
# Reuse output from Test 4 to avoid running the script twice
if echo "$output" | grep -qE "CLEANUP|VALIDATION"; then
    echo "  PASS: --quick output contains CLEANUP and/or VALIDATION section"
    (( PASS++ ))
else
    echo "  FAIL: --quick output missing CLEANUP/VALIDATION sections" >&2
    (( FAIL++ ))
fi

# ── Test 6: Script uses section() function for structured output ──────────────
echo "Test 6: Script uses section() function for structured output"
if grep -q "section()" "$SCRIPT" || grep -q "^section " "$SCRIPT"; then
    echo "  PASS: script uses section() function"
    (( PASS++ ))
else
    echo "  FAIL: script does not use section() function" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
