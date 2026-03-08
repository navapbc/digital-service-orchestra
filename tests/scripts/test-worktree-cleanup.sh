#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-cleanup.sh
# Baseline tests for scripts/worktree-cleanup.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-cleanup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree-cleanup.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-worktree-cleanup.sh ==="

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
run_test "--help exits 0 and prints Usage" 0 "[Uu]sage" bash "$SCRIPT" --help

# ── Test 3: Unknown option exits non-zero ─────────────────────────────────────
echo "Test 3: Unknown option exits non-zero"
run_test "unknown option exits 1" 1 "" bash "$SCRIPT" --unknown-flag-xyz

# ── Test 4: --dry-run exits 0 ─────────────────────────────────────────────────
echo "Test 4: --dry-run exits 0"
exit_code=0
bash "$SCRIPT" --dry-run 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: --dry-run exits 0"
    (( PASS++ ))
else
    echo "  FAIL: --dry-run exited $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 5: WORKTREE_CLEANUP_ENABLED=1 with --dry-run exits 0 ────────────────
echo "Test 5: WORKTREE_CLEANUP_ENABLED=1 + --dry-run exits 0"
exit_code=0
WORKTREE_CLEANUP_ENABLED=1 bash "$SCRIPT" --dry-run 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: WORKTREE_CLEANUP_ENABLED=1 + --dry-run exits 0"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 0, got $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 6: --all --force --dry-run exits 0 (non-interactive path) ───────────
echo "Test 6: --all --force --dry-run exits 0"
exit_code=0
WORKTREE_CLEANUP_ENABLED=1 bash "$SCRIPT" --all --force --dry-run 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: --all --force --dry-run exits 0"
    (( PASS++ ))
else
    echo "  FAIL: --all --force --dry-run exited $exit_code" >&2
    (( FAIL++ ))
fi

# ── Test 7: Script contains stash safety check ────────────────────────────────
echo "Test 7: Script contains stash safety check"
if bash -n "$SCRIPT" 2>/dev/null && grep -q "stash" "$SCRIPT"; then
    echo "  PASS: script contains stash safety check"
    (( PASS++ ))
else
    echo "  FAIL: script does not contain stash safety check" >&2
    (( FAIL++ ))
fi

# ── Test 8: Script checks for WORKTREE_CLEANUP_ENABLED opt-in ────────────────
echo "Test 8: Script references WORKTREE_CLEANUP_ENABLED opt-in"
if grep -qE "WORKTREE_CLEANUP_ENABLED|CLEANUP_ENABLED|--non-interactive|non_interactive" "$SCRIPT"; then
    echo "  PASS: script references opt-in mechanism"
    (( PASS++ ))
else
    echo "  FAIL: script does not reference WORKTREE_CLEANUP_ENABLED opt-in" >&2
    (( FAIL++ ))
fi

# ── Test 9: No bash syntax errors ────────────────────────────────────────────
echo "Test 9: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 10: Script references age/time check ────────────────────────────────
echo "Test 10: Script checks worktree age"
if grep -qE "WT_AGE|WORKTREE_AGE|age_days|AGE_DAYS|age_check|7.*days|days.*7|older.*7|7.*older" "$SCRIPT"; then
    echo "  PASS: script contains age safety check"
    (( PASS++ ))
else
    echo "  FAIL: script does not contain age safety check" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
