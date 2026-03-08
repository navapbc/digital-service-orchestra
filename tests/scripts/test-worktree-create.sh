#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-create.sh
# Baseline tests for scripts/worktree-create.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-create.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree-create.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-worktree-create.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: --help exits 0 with usage text ───────────────────────────────────
echo "Test 2: --help exits 0 with usage text"
run_test "--help exits 0 and prints usage" 0 "[Uu]sage|[Oo]ption|--name" bash "$SCRIPT" --help

# ── Test 3: Unknown option exits non-zero ────────────────────────────────────
echo "Test 3: Unknown option exits non-zero"
run_test "unknown option exits 1" 1 "" bash "$SCRIPT" --unknown-flag-xyz

# ── Test 4: No bash syntax errors ─────────────────────────────────────────────
echo "Test 4: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 5: Script requires git repo (exits non-zero outside git) ─────────────
echo "Test 5: Script exits non-zero when not in a git repo"
exit_code=0
TMP_DIR=$(mktemp -d)
( cd "$TMP_DIR" && bash "$SCRIPT" 2>/dev/null ) || exit_code=$?
rmdir "$TMP_DIR" 2>/dev/null || true
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero outside git repo (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit outside git repo" >&2
    (( FAIL++ ))
fi

# ── Test 6: Script supports --name= option ────────────────────────────────────
echo "Test 6: Script supports --name= option"
if grep -q "\-\-name" "$SCRIPT"; then
    echo "  PASS: script supports --name= option"
    (( PASS++ ))
else
    echo "  FAIL: script does not support --name= option" >&2
    (( FAIL++ ))
fi

# ── Test 7: Script supports --validation= option ─────────────────────────────
echo "Test 7: Script supports --validation= option"
if grep -q "\-\-validation" "$SCRIPT"; then
    echo "  PASS: script supports --validation= option"
    (( PASS++ ))
else
    echo "  FAIL: script does not support --validation= option" >&2
    (( FAIL++ ))
fi

# ── Test 8: Script outputs path to stdout on success ─────────────────────────
echo "Test 8: Script documents stdout path output behavior"
if grep -qE "Prints the created|echo.*path|path.*stdout" "$SCRIPT"; then
    echo "  PASS: script documents path output to stdout"
    (( PASS++ ))
else
    echo "  FAIL: script missing stdout path documentation" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
