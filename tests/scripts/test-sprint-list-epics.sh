#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-sprint-list-epics.sh
# Baseline tests for scripts/sprint-list-epics.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-sprint-list-epics.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sprint-list-epics.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-sprint-list-epics.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 5: No bash syntax errors ─────────────────────────────────────────────
# Run before the live invocations so we can skip them on syntax errors.
echo "Test 5: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Single invocation: capture output and exit code once (Tests 2, 3, 6) ────
# The script scans all .tickets/ files which can be slow on large repos.
# Run it once and reuse the output to avoid repeated full-scan overhead.
script_exit=0
script_output=""
script_output=$(bash "$SCRIPT" 2>&1) || script_exit=$?

# Also run --all once (Test 4)
all_exit=0
bash "$SCRIPT" --all >/dev/null 2>&1 || all_exit=$?

# ── Test 2: No args exits within valid range (0, 1, or 2) ────────────────────
echo "Test 2: No args exits within valid range (0=found, 1=none, 2=all-blocked)"
if [ "$script_exit" -ge 0 ] && [ "$script_exit" -le 2 ]; then
    echo "  PASS: no args exits with valid code ($script_exit)"
    (( PASS++ ))
else
    echo "  FAIL: no args exited $script_exit (expected 0, 1, or 2)" >&2
    (( FAIL++ ))
fi

# ── Test 3: Output contains epic entries with priority markers ───────────────
echo "Test 3: Output format contains epic IDs and priorities"
if echo "$script_output" | grep -qE "P[0-9*]|lockpick-doc-to-logic"; then
    echo "  PASS: output contains epic entries with priority markers"
    (( PASS++ ))
else
    echo "  FAIL: output missing expected epic format" >&2
    (( FAIL++ ))
fi

# ── Test 4: --all flag is accepted ───────────────────────────────────────────
echo "Test 4: --all flag is accepted"
if [ "$all_exit" -le 2 ]; then
    echo "  PASS: --all exits 0, 1, or 2 (exit $all_exit)"
    (( PASS++ ))
else
    echo "  FAIL: --all exited $all_exit (expected 0-2)" >&2
    (( FAIL++ ))
fi

# ── Test 6: Output uses expected priority format (P* or P<n>) ────────────────
echo "Test 6: Output uses expected priority format"
if echo "$script_output" | grep -qE "P\*|P[0-9]"; then
    echo "  PASS: output uses expected priority format (P* or P<n>)"
    (( PASS++ ))
else
    echo "  FAIL: output missing expected priority format" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
