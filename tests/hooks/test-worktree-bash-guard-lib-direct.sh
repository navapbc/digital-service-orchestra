#!/usr/bin/env bash
# tests/hooks/test-worktree-bash-guard-lib-direct.sh
# SDET audit P1-6: thin direct-sourcing test for the hook_worktree_bash_guard
# library function in plugins/dso/hooks/lib/pre-bash-functions.sh.
#
# Complements (does NOT replace) the existing dispatcher tests — those drive
# the hook via the pre-bash dispatcher. This test sources the library and
# calls the function with a matrix of JSON inputs directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/hooks/lib/pre-bash-functions.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-bash-guard-lib-direct.sh ==="

if [[ ! -f "$LIB" ]]; then
    echo "SKIP: $LIB not found"
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

# shellcheck disable=SC1090
source "$LIB"

if ! type hook_worktree_bash_guard >/dev/null 2>&1; then
    echo "FAIL: hook_worktree_bash_guard not defined after sourcing $LIB" >&2
    exit 1
fi

# ─── Test 1 — return 0 when command does not reference main repo path ────────
echo ""
echo "--- test_returns_0_when_command_unrelated_to_main_repo ---"

test_returns_0_when_command_unrelated_to_main_repo() {
    _snapshot_fail
    # Command that touches no main-repo path — the guard's path-overlap check
    # should short-circuit to allow.
    local input='{"tool_input":{"command":"echo hello"}}'
    local rc=0
    hook_worktree_bash_guard "$input" 2>/dev/null || rc=$?
    assert_eq "unrelated command allowed (rc=0)" "0" "$rc"
    assert_pass_if_clean "test_returns_0_when_command_unrelated_to_main_repo"
}
test_returns_0_when_command_unrelated_to_main_repo

# ─── Test 2 — return 0 when JSON has no .tool_input.command field ────────────
echo ""
echo "--- test_returns_0_when_command_field_missing ---"

test_returns_0_when_command_field_missing() {
    _snapshot_fail
    local input='{"tool_input":{}}'
    local rc=0
    hook_worktree_bash_guard "$input" 2>/dev/null || rc=$?
    assert_eq "missing command field allowed (rc=0)" "0" "$rc"
    assert_pass_if_clean "test_returns_0_when_command_field_missing"
}
test_returns_0_when_command_field_missing

# ─── Test 3 — return 0 when input is malformed JSON ──────────────────────────
echo ""
echo "--- test_returns_0_when_input_malformed ---"

test_returns_0_when_input_malformed() {
    _snapshot_fail
    local input='not-json'
    local rc=0
    hook_worktree_bash_guard "$input" 2>/dev/null || rc=$?
    # The function uses a trap that returns 0 on ERR — should not crash.
    assert_eq "malformed input handled gracefully (rc=0)" "0" "$rc"
    assert_pass_if_clean "test_returns_0_when_input_malformed"
}
test_returns_0_when_input_malformed

print_summary
