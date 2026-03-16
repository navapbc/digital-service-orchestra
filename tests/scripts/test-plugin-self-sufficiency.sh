#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-plugin-self-sufficiency.sh
# Verifies that worktree-cleanup.sh (and other migrated scripts) are present
# in lockpick-workflow/scripts/ (the plugin canonical location) and that their
# exec wrappers in scripts/ delegate correctly.
#
# Scope: migration completeness checks for the worktree-cleanup.sh migration.
# For the full plugin self-sufficiency suite (skills, docs, commands, etc.),
# see lockpick-workflow/tests/test-plugin-self-sufficiency.sh.
#
# Usage: bash lockpick-workflow/tests/scripts/test-plugin-self-sufficiency.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-plugin-self-sufficiency (scripts) ==="

# ── Test 1: worktree-cleanup.sh is present in lockpick-workflow/scripts/ ──────
echo "Test 1: worktree-cleanup.sh is in lockpick-workflow/scripts/"
if [[ -f "$PLUGIN_ROOT/scripts/worktree-cleanup.sh" ]]; then
    echo "  PASS: worktree-cleanup.sh exists in lockpick-workflow/scripts/"
    (( PASS++ ))
else
    echo "  FAIL: worktree-cleanup.sh missing from lockpick-workflow/scripts/" >&2
    (( FAIL++ ))
fi

# ── Test 2: worktree-cleanup.sh is executable in plugin ───────────────────────
echo "Test 2: worktree-cleanup.sh is executable in lockpick-workflow/scripts/"
if [[ -x "$PLUGIN_ROOT/scripts/worktree-cleanup.sh" ]]; then
    echo "  PASS: worktree-cleanup.sh is executable"
    (( PASS++ ))
else
    echo "  FAIL: worktree-cleanup.sh is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 3: scripts/worktree-cleanup.sh exec wrapper exists ───────────────────
echo "Test 3: scripts/worktree-cleanup.sh exec wrapper exists"
if [[ -f "$REPO_ROOT/scripts/worktree-cleanup.sh" ]]; then
    echo "  PASS: scripts/worktree-cleanup.sh wrapper exists"
    (( PASS++ ))
else
    echo "  FAIL: scripts/worktree-cleanup.sh wrapper missing" >&2
    (( FAIL++ ))
fi

# ── Test 4: wrapper is thin (< 15 lines) ──────────────────────────────────────
echo "Test 4: scripts/worktree-cleanup.sh wrapper is thin (< 15 lines)"
WRAPPER="$REPO_ROOT/scripts/worktree-cleanup.sh"
if [[ -f "$WRAPPER" ]]; then
    line_count="$(wc -l < "$WRAPPER" | tr -d ' ')"
    if [[ "$line_count" -lt 15 ]]; then
        echo "  PASS: wrapper is thin ($line_count lines < 15)"
        (( PASS++ ))
    else
        echo "  FAIL: wrapper is not thin ($line_count lines, expected < 15)" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: wrapper not found"
fi

# ── Test 5: wrapper contains exec delegation ──────────────────────────────────
echo "Test 5: scripts/worktree-cleanup.sh wrapper contains exec delegation"
if [[ -f "$WRAPPER" ]]; then
    if grep -q 'exec' "$WRAPPER"; then
        echo "  PASS: wrapper contains exec delegation"
        (( PASS++ ))
    else
        echo "  FAIL: wrapper does not contain exec delegation keyword" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: wrapper not found"
fi

# ── Test 6: wrapper delegates to lockpick-workflow/scripts/worktree-cleanup.sh ─
echo "Test 6: wrapper exec-delegates to lockpick-workflow canonical path"
if [[ -f "$WRAPPER" ]]; then
    if grep -q 'lockpick-workflow/scripts/worktree-cleanup.sh' "$WRAPPER"; then
        echo "  PASS: wrapper references lockpick-workflow/scripts/worktree-cleanup.sh"
        (( PASS++ ))
    else
        echo "  FAIL: wrapper does not reference lockpick-workflow/scripts/worktree-cleanup.sh" >&2
        (( FAIL++ ))
    fi
else
    echo "  SKIP: wrapper not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
