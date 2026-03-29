#!/usr/bin/env bash
# tests/scripts/test-worktree-sync-from-main.sh
# Tests for plugins/dso/scripts/worktree-sync-from-main.sh
#
# Usage: bash tests/scripts/test-worktree-sync-from-main.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-sync-from-main.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-worktree-sync-from-main.sh ==="

# ── Test 1: Script exists at plugin location ─────────────────────────────────
echo "Test 1: Script exists at plugin location"
if [ -f "$SCRIPT" ]; then
    echo "  PASS: script exists at plugins/dso/scripts/worktree-sync-from-main.sh"
    (( PASS++ ))
else
    echo "  FAIL: script not found at $SCRIPT" >&2
    (( FAIL++ ))
fi

# ── Test 2: Script is executable ─────────────────────────────────────────────
echo "Test 2: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 3: No bash syntax errors ────────────────────────────────────────────
echo "Test 3: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 4: --help exits 0 with usage text ───────────────────────────────────
echo "Test 4: --help exits 0 with usage text"
run_test "--help exits 0 and prints usage" 0 "[Uu]sage|[Oo]ption|--skip" bash "$SCRIPT" --help

# ── Test 5: Unknown option exits non-zero ────────────────────────────────────
echo "Test 5: Unknown option exits non-zero"
run_test "unknown option exits 1" 1 "" bash "$SCRIPT" --unknown-option-xyz

# ── Test 6: Script fails outside a git repo ──────────────────────────────────
echo "Test 6: Script exits non-zero when not in a git repo"
TMP_NOGIT=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_NOGIT")
exit_code=0
( cd "$TMP_NOGIT" && bash "$SCRIPT" 2>/dev/null ) || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero outside git repo (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit outside git repo" >&2
    (( FAIL++ ))
fi

# ── Test 7: Script fails when run from main repo (not a worktree) ────────────
echo "Test 7: Script exits non-zero when run from main repo (not a worktree)"
TMP_MAINREPO=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_MAINREPO")
git init -b main "$TMP_MAINREPO" &>/dev/null
git -C "$TMP_MAINREPO" commit --allow-empty -m "init" &>/dev/null
exit_code=0
( cd "$TMP_MAINREPO" && bash "$SCRIPT" 2>/dev/null ) || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero when run from main repo (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit when run from main repo" >&2
    (( FAIL++ ))
fi

# ── Test 8: Script contains --skip-tickets and --skip-code options ────────────
echo "Test 8: Script supports --skip-tickets and --skip-code options"
if grep -q "\-\-skip-tickets" "$SCRIPT" && grep -q "\-\-skip-code" "$SCRIPT"; then
    echo "  PASS: script supports --skip-tickets and --skip-code"
    (( PASS++ ))
else
    echo "  FAIL: script missing --skip-tickets and/or --skip-code options" >&2
    (( FAIL++ ))
fi

# ── Test 9: Script handles detached HEAD gracefully ──────────────────────────
echo "Test 9: Script references current branch detection"
if grep -q "branch --show-current\|CURRENT_BRANCH" "$SCRIPT"; then
    echo "  PASS: script detects current branch"
    (( PASS++ ))
else
    echo "  FAIL: script missing branch detection" >&2
    (( FAIL++ ))
fi

# ── Test 10: Script syncs tickets branch ─────────────────────────────────────
echo "Test 10: Script handles .tickets-tracker/ ticket sync"
if grep -q "tickets-tracker\|tickets branch" "$SCRIPT"; then
    echo "  PASS: script references tickets-tracker sync"
    (( PASS++ ))
else
    echo "  FAIL: script missing .tickets-tracker/ sync logic" >&2
    (( FAIL++ ))
fi

# ── Test 11: Functional smoke test — worktree with no remote ─────────────────
echo "Test 11: Script runs in a real worktree (no remote, uses --skip-tickets)"
TMP_SMOKE=$(mktemp -d)
TMP_WORKTREES=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_SMOKE" "$TMP_WORKTREES")

(
    set -euo pipefail
    git init -b main "$TMP_SMOKE" &>/dev/null
    git -C "$TMP_SMOKE" commit --allow-empty -m "init" &>/dev/null

    WT_PATH="$TMP_WORKTREES/wt-smoke"
    git -C "$TMP_SMOKE" worktree add "$WT_PATH" -b wt-smoke &>/dev/null

    # In the worktree, run the script with --skip-tickets (no remote to fetch from)
    # The fetch will fail gracefully and script should still exit 0
    cd "$WT_PATH"
    bash "$SCRIPT" --skip-tickets 2>&1
) && wt_exit=0 || wt_exit=$?

# Clean up worktree before temp dirs are removed
git -C "$TMP_SMOKE" worktree remove --force "$TMP_WORKTREES/wt-smoke" 2>/dev/null || true

if [ "$wt_exit" -eq 0 ]; then
    echo "  PASS: script ran successfully in worktree (exit 0)"
    (( PASS++ ))
else
    echo "  FAIL: script exited $wt_exit in worktree" >&2
    (( FAIL++ ))
fi

# ── Test 12: Script prints 'Sync complete' on success ────────────────────────
echo "Test 12: Script prints 'Sync complete' on success"
TMP_SMOKE2=$(mktemp -d)
TMP_WORKTREES2=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_SMOKE2" "$TMP_WORKTREES2")

sync_output=""
(
    set -euo pipefail
    git init -b main "$TMP_SMOKE2" &>/dev/null
    git -C "$TMP_SMOKE2" commit --allow-empty -m "init" &>/dev/null

    WT_PATH2="$TMP_WORKTREES2/wt-smoke2"
    git -C "$TMP_SMOKE2" worktree add "$WT_PATH2" -b wt-smoke2 &>/dev/null

    cd "$WT_PATH2"
    bash "$SCRIPT" --skip-tickets --skip-code 2>&1
) && sync_output=$? || sync_output=$?

git -C "$TMP_SMOKE2" worktree remove --force "$TMP_WORKTREES2/wt-smoke2" 2>/dev/null || true

# Re-run to capture output
TMP_SMOKE3=$(mktemp -d)
TMP_WORKTREES3=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_SMOKE3" "$TMP_WORKTREES3")

git init -b main "$TMP_SMOKE3" &>/dev/null
git -C "$TMP_SMOKE3" commit --allow-empty -m "init" &>/dev/null
WT_PATH3="$TMP_WORKTREES3/wt-smoke3"
git -C "$TMP_SMOKE3" worktree add "$WT_PATH3" -b wt-smoke3 &>/dev/null

captured_output=""
exit_code=0
captured_output=$(cd "$WT_PATH3" && bash "$SCRIPT" --skip-tickets --skip-code 2>&1) || exit_code=$?

git -C "$TMP_SMOKE3" worktree remove --force "$WT_PATH3" 2>/dev/null || true

if echo "$captured_output" | grep -q "Sync complete"; then
    echo "  PASS: script prints 'Sync complete' on success"
    (( PASS++ ))
else
    echo "  FAIL: script output missing 'Sync complete': $captured_output" >&2
    (( FAIL++ ))
fi

print_results
