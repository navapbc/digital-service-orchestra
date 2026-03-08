#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-create.sh
# Tests for lockpick-workflow/scripts/worktree-create.sh (plugin location)
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-create.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/worktree-create.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-worktree-create.sh ==="

# ── Test 1: Script exists at plugin location ─────────────────────────────────
echo "Test 1: Script exists at plugin location"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable at lockpick-workflow/scripts/"
    (( PASS++ ))
else
    echo "  FAIL: script not found or not executable at lockpick-workflow/scripts/" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 3: --help exits 0 with usage text ───────────────────────────────────
echo "Test 3: --help exits 0 with usage text"
run_test "--help exits 0 and prints usage" 0 "[Uu]sage|[Oo]ption|--name" bash "$SCRIPT" --help

# ── Test 4: Unknown option exits non-zero ────────────────────────────────────
echo "Test 4: Unknown option exits non-zero"
run_test "unknown option exits 1" 1 "" bash "$SCRIPT" --unknown-flag-xyz

# ── Test 5: Script requires git repo (exits non-zero outside git) ────────────
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

# ── Test 6: Script supports --name= option ──────────────────────────────────
echo "Test 6: Script supports --name= option"
if grep -q "\-\-name" "$SCRIPT"; then
    echo "  PASS: script supports --name= option"
    (( PASS++ ))
else
    echo "  FAIL: script does not support --name= option" >&2
    (( FAIL++ ))
fi

# ── Test 7: Script supports --validation= option ────────────────────────────
echo "Test 7: Script supports --validation= option"
if grep -q "\-\-validation" "$SCRIPT"; then
    echo "  PASS: script supports --validation= option"
    (( PASS++ ))
else
    echo "  FAIL: script does not support --validation= option" >&2
    (( FAIL++ ))
fi

# ── Test 8: Config-driven post_create_cmd lookup ─────────────────────────────
echo "Test 8: Script uses config-driven post_create_cmd"
if grep -qE "post_create_cmd|read-config" "$SCRIPT"; then
    echo "  PASS: script references post_create_cmd or read-config"
    (( PASS++ ))
else
    echo "  FAIL: script missing post_create_cmd / read-config lookup" >&2
    (( FAIL++ ))
fi

# ── Test 9: Repo-name-derived worktree directory default ─────────────────────
echo "Test 9: Script derives worktree directory from repo name"
if grep -qE 'basename.*repo|repo.*name|worktree.*dir.*base' "$SCRIPT"; then
    echo "  PASS: script derives worktree directory from repo name"
    (( PASS++ ))
else
    echo "  FAIL: script missing repo-name-derived worktree directory logic" >&2
    (( FAIL++ ))
fi

# ── Test 10: Session artifact_prefix config lookup ───────────────────────────
echo "Test 10: Script looks up session.artifact_prefix config"
if grep -q "artifact_prefix" "$SCRIPT"; then
    echo "  PASS: script references artifact_prefix"
    (( PASS++ ))
else
    echo "  FAIL: script missing artifact_prefix config lookup" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
