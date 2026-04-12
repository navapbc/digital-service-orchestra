#!/usr/bin/env bash
# tests/scripts/test-smoke-test-portable.sh
# TDD tests for scripts/smoke-test-portable.sh
#
# Usage: bash tests/scripts/test-smoke-test-portable.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/smoke-test-portable.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-smoke-test-portable.sh ==="

# ── Test 1: test_smoke_test_exists — script exists and is executable ──────────
echo "Test 1: test_smoke_test_exists — script exists and is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: scripts/smoke-test-portable.sh exists and is executable"
    (( PASS++ ))
else
    echo "  FAIL: scripts/smoke-test-portable.sh missing or not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: test_smoke_test_syntax — no bash syntax errors ───────────────────
echo "Test 2: test_smoke_test_syntax — no bash syntax errors"
if [ -f "$SCRIPT" ] && bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors in smoke-test-portable.sh"
    (( PASS++ ))
elif [ ! -f "$SCRIPT" ]; then
    echo "  FAIL: smoke-test-portable.sh does not exist (cannot check syntax)" >&2
    (( FAIL++ ))
else
    echo "  FAIL: syntax errors found in $SCRIPT" >&2
    (( FAIL++ ))
fi

# ── Test 3: test_smoke_test_runs — runs successfully with real plugin ─────────
echo "Test 3: test_smoke_test_runs — script exits 0 with real plugin"
if [ -x "$SCRIPT" ]; then
    exit_code=0
    CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: script exited 0 when run against the real plugin"
        (( PASS++ ))
    else
        echo "  FAIL: script exited $exit_code when run against the real plugin" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: smoke-test-portable.sh missing or not executable — cannot run" >&2
    (( FAIL++ ))
fi

# ── Test 4: test_smoke_test_cleanup — no /tmp/lw-smoke-* dirs remain ─────────
echo "Test 4: test_smoke_test_cleanup — /tmp/lw-smoke-* cleaned up after run"
# Clean any leftovers from earlier tests before measuring this invocation (1425-2803)
rm -rf /tmp/lw-smoke-* 2>/dev/null || true
if [ -x "$SCRIPT" ]; then
    CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" bash "$SCRIPT" >/dev/null 2>&1 || true
    # Wait briefly for async rm -rf to finish (large plugin dirs race with process exit)
    leftover_count=1
    for _i in 1 2 3 4; do
        leftover_count=$(ls -d /tmp/lw-smoke-* 2>/dev/null | wc -l | tr -d ' ')
        [ "$leftover_count" -eq 0 ] && break
        sleep 0.5
    done
    if [ "$leftover_count" -eq 0 ]; then
        echo "  PASS: no /tmp/lw-smoke-* dirs remain after script exits"
        (( PASS++ ))
    else
        echo "  FAIL: $leftover_count /tmp/lw-smoke-* dir(s) remain after script exits" >&2
        # Clean up the leftovers to avoid polluting further tests
        rm -rf /tmp/lw-smoke-* 2>/dev/null || true
        (( FAIL++ ))
    fi
else
    echo "  FAIL: smoke-test-portable.sh missing or not executable — cannot check cleanup" >&2
    (( FAIL++ ))
fi

# ── Test 5: test_smoke_test_produces_summary — output contains PASS marker ───
echo "Test 5: test_smoke_test_produces_summary — output contains PASS summary"
if [ -x "$SCRIPT" ]; then
    output=""
    output=$(CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" bash "$SCRIPT" 2>&1) || true
    if [[ "$output" == *PASS* ]]; then
        echo "  PASS: output contains PASS summary marker"
        (( PASS++ ))
    else
        echo "  FAIL: output does not contain PASS marker" >&2
        echo "  Output was: $output" >&2
        (( FAIL++ ))
    fi
else
    echo "  FAIL: smoke-test-portable.sh missing or not executable — cannot check output" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ]
