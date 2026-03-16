#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-staging-smoke-test.sh
# Tests for lockpick-workflow/scripts/staging-smoke-test.sh (canonical)
# and scripts/staging-smoke-test.sh (exec wrapper).
#
# Usage: bash lockpick-workflow/tests/scripts/test-staging-smoke-test.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/staging-smoke-test.sh"
WRAPPER="$REPO_ROOT/scripts/staging-smoke-test.sh"
PROMPT="$PLUGIN_ROOT/skills/validate-work/prompts/staging-environment-test.md"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-staging-smoke-test.sh ==="

# ── Test 1: Script exists and is executable ───────────────────────────────────
echo "Test 1: test_staging_smoke_test_script_exists — script exists and is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: lockpick-workflow/scripts/staging-smoke-test.sh exists and is executable"
    (( PASS++ ))
else
    echo "  FAIL: lockpick-workflow/scripts/staging-smoke-test.sh missing or not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ────────────────────────────────────────────
echo "Test 2: No bash syntax errors in canonical script"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found in $SCRIPT" >&2
    (( FAIL++ ))
fi

# ── Test 3: Exec wrapper exists ───────────────────────────────────────────────
echo "Test 3: Exec wrapper scripts/staging-smoke-test.sh exists"
if [ -f "$WRAPPER" ]; then
    echo "  PASS: scripts/staging-smoke-test.sh exists"
    (( PASS++ ))
else
    echo "  FAIL: scripts/staging-smoke-test.sh does not exist" >&2
    (( FAIL++ ))
fi

# ── Test 4: Exec wrapper delegates to canonical copy ─────────────────────────
echo "Test 4: Exec wrapper delegates to lockpick-workflow/scripts/staging-smoke-test.sh"
if [ -f "$WRAPPER" ]; then
    if grep -q 'exec' "$WRAPPER" && grep -q 'lockpick-workflow/scripts/staging-smoke-test.sh' "$WRAPPER"; then
        echo "  PASS: wrapper exec-delegates to canonical script"
        (( PASS++ ))
    else
        echo "  FAIL: wrapper does not exec-delegate to lockpick-workflow/scripts/staging-smoke-test.sh" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: wrapper does not exist"
fi

# ── Test 5: Script exits non-zero when STAGING_URL is empty ──────────────────
echo "Test 5: Script exits non-zero without required STAGING_URL argument"
exit_code=0
STAGING_URL='' bash "$SCRIPT" 2>/dev/null || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: script exited non-zero (exit $exit_code) when STAGING_URL is empty"
    (( PASS++ ))
else
    echo "  FAIL: script exited 0 when STAGING_URL is empty — should require it" >&2
    (( FAIL++ ))
fi

# ── Test 6: Prompt file references staging-smoke-test.sh (not inline block) ──
echo "Test 6: staging-environment-test.md references staging-smoke-test.sh"
if grep -q 'staging-smoke-test.sh' "$PROMPT"; then
    echo "  PASS: prompt references staging-smoke-test.sh"
    (( PASS++ ))
else
    echo "  FAIL: prompt does not reference staging-smoke-test.sh" >&2
    (( FAIL++ ))
fi

# ── Test 7: Inline curl health-check block is no longer in prompt file ────────
echo "Test 7: Inline curl health-check block is removed from staging-environment-test.md"
# The original inline block had: HEALTH_STATUS=\$(curl -sf -o /dev/null
if grep -q 'HEALTH_STATUS=\$(curl' "$PROMPT"; then
    echo "  FAIL: inline curl health-check block still present in prompt" >&2
    (( FAIL++ ))
else
    echo "  PASS: inline curl health-check block removed from prompt"
    (( PASS++ ))
fi

# ── Test 8: Script contains the expected health-check logic ──────────────────
echo "Test 8: Script contains health-check curl logic"
if [ -f "$SCRIPT" ] && grep -q 'HEALTH_STATUS' "$SCRIPT" && grep -q 'curl' "$SCRIPT"; then
    echo "  PASS: script contains health-check curl logic"
    (( PASS++ ))
else
    echo "  FAIL: script missing health-check curl logic" >&2
    (( FAIL++ ))
fi

# ── Test 9: Script contains route scan loop ───────────────────────────────────
echo "Test 9: Script contains route scan loop"
if [ -f "$SCRIPT" ] && grep -q 'ROUTE_LIST' "$SCRIPT"; then
    echo "  PASS: script contains route scan loop"
    (( PASS++ ))
else
    echo "  FAIL: script missing route scan loop" >&2
    (( FAIL++ ))
fi

# ── Test 10: Script accepts STAGING_URL env var or positional arg ─────────────
echo "Test 10: Script accepts STAGING_URL as env var or positional arg"
if [ -f "$SCRIPT" ] && (grep -q 'STAGING_URL' "$SCRIPT" || grep -q '\$1' "$SCRIPT"); then
    echo "  PASS: script references STAGING_URL or positional arg"
    (( PASS++ ))
else
    echo "  FAIL: script does not accept STAGING_URL" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
