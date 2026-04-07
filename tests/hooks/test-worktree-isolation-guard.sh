#!/usr/bin/env bash
# Tests worktree-isolation-guard.sh (Agent isolation block) — see test-worktree-guard.sh for worktree-edit-guard.sh (Edit/Write block)
#
# worktree-isolation-guard.sh is a PreToolUse hook that blocks Agent tool calls
# that specify isolation: "worktree". Worktree isolation breaks shared state
# (artifacts dir, review findings, diff hashes).
#
# Tests:
#   test_allows_agent_with_valid_auth_marker
#   test_blocks_agent_without_auth_marker
#   test_blocks_agent_with_stale_auth_marker
#   test_cleans_stale_markers
#   test_allows_agent_without_isolation
#   test_allows_non_agent_tools
#   test_handles_null_tool_input
#
# Usage: bash tests/hooks/test-worktree-isolation-guard.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

HOOK="$DSO_PLUGIN_DIR/hooks/worktree-isolation-guard.sh"

# Cleanup trap: remove any marker files created by this test suite
_TEST_MARKER_PREFIX="/tmp/worktree-isolation-authorized-test-"
trap 'rm -f "${_TEST_MARKER_PREFIX}"* 2>/dev/null || true' EXIT

# Helper: run hook with given JSON input, return exit code via echo
# Sets WORKTREE_ISOLATION_ENABLED=true to test the auth marker enforcement path.
run_hook_exit() {
    local input="$1"
    local exit_code=0
    printf '%s' "$input" | WORKTREE_ISOLATION_ENABLED=true bash "$HOOK" >/dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Helper: run hook with given JSON input, return stdout
run_hook_stdout() {
    local input="$1"
    printf '%s' "$input" | WORKTREE_ISOLATION_ENABLED=true bash "$HOOK" 2>/dev/null || true
}

# Helper: assert stdout does NOT contain a substring (uses FAIL if it does)
assert_not_contains() {
    local label="$1" substring="$2" string="$3"
    if [[ "$string" != *"$substring"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  should NOT contain: %s\n  actual:             %s\n" "$label" "$substring" "$string" >&2
    fi
}

# ============================================================
# test_allows_agent_with_valid_auth_marker
# Agent tool call with isolation: "worktree" AND a valid auth marker file
# (containing current PID) must be ALLOWED (no deny in output).
# RED: current guard categorically denies — this test will FAIL.
# ============================================================
echo "--- test_allows_agent_with_valid_auth_marker ---"
_MARKER_FILE="${_TEST_MARKER_PREFIX}$$"
echo "$$" > "$_MARKER_FILE"
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","prompt":"authorized sub-agent"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_allows_agent_with_valid_auth_marker: exits 0" "0" "$_exit_code"
assert_not_contains "test_allows_agent_with_valid_auth_marker: no deny in stdout" '"permissionDecision": "deny"' "$_stdout"
rm -f "$_MARKER_FILE"

# ============================================================
# test_blocks_agent_without_auth_marker
# Agent tool call with isolation: "worktree" and NO marker file must be denied.
# (Renamed from test_blocks_agent_with_worktree_isolation)
# ============================================================
echo "--- test_blocks_agent_without_auth_marker ---"
# Ensure no marker files exist
rm -f "${_TEST_MARKER_PREFIX}"* 2>/dev/null || true
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","prompt":"do something"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_blocks_agent_without_auth_marker: exits 0" "0" "$_exit_code"
assert_contains "test_blocks_agent_without_auth_marker: stdout contains permissionDecision" "permissionDecision" "$_stdout"
assert_contains "test_blocks_agent_without_auth_marker: permissionDecision is deny" '"permissionDecision": "deny"' "$_stdout"

# ============================================================
# test_blocks_agent_with_stale_auth_marker
# Agent tool call with isolation: "worktree" and a marker file containing
# a dead PID (99999) must be denied. Stale marker treated as absent.
# RED: current guard denies categorically, but new guard must check PID liveness.
# This test passes for the wrong reason (deny) but verifies deny behavior still
# occurs for stale markers after implementation.
# ============================================================
echo "--- test_blocks_agent_with_stale_auth_marker ---"
_STALE_MARKER="${_TEST_MARKER_PREFIX}stale-$$"
echo "99999" > "$_STALE_MARKER"
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","prompt":"stale auth agent"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_blocks_agent_with_stale_auth_marker: exits 0" "0" "$_exit_code"
assert_contains "test_blocks_agent_with_stale_auth_marker: permissionDecision is deny" '"permissionDecision": "deny"' "$_stdout"
rm -f "$_STALE_MARKER"

# ============================================================
# test_cleans_stale_markers
# After running the guard with stale markers (dead PIDs), the marker files
# must be removed by the guard.
# RED: current guard does not clean marker files at all.
# ============================================================
echo "--- test_cleans_stale_markers ---"
_STALE1="${_TEST_MARKER_PREFIX}stale1-$$"
_STALE2="${_TEST_MARKER_PREFIX}stale2-$$"
echo "99999" > "$_STALE1"
echo "99998" > "$_STALE2"
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","prompt":"cleanup test"}}'
# Run the guard (output not needed — side effect is cleanup)
run_hook_stdout "$_INPUT" >/dev/null 2>/dev/null || true
_stale1_exists=0
_stale2_exists=0
[[ -f "$_STALE1" ]] && _stale1_exists=1
[[ -f "$_STALE2" ]] && _stale2_exists=1
assert_eq "test_cleans_stale_markers: stale marker 1 removed" "0" "$_stale1_exists"
assert_eq "test_cleans_stale_markers: stale marker 2 removed" "0" "$_stale2_exists"
# Clean up in case guard didn't (so subsequent tests are unaffected)
rm -f "$_STALE1" "$_STALE2" 2>/dev/null || true

# ============================================================
# test_allows_agent_without_isolation
# Agent tool call with no isolation field must be allowed (exit 0, no deny output).
# ============================================================
echo "--- test_allows_agent_without_isolation ---"
_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do something without isolation"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_allows_agent_without_isolation: exits 0" "0" "$_exit_code"
assert_ne "test_allows_agent_without_isolation: no deny in stdout" '"permissionDecision": "deny"' "$_stdout"

# ============================================================
# test_allows_non_agent_tools
# Non-Agent tool calls (e.g., Bash) must pass through without deny.
# ============================================================
echo "--- test_allows_non_agent_tools ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_allows_non_agent_tools: exits 0" "0" "$_exit_code"
assert_ne "test_allows_non_agent_tools: no deny in stdout" '"permissionDecision": "deny"' "$_stdout"

# Also check Edit tool is allowed through
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_allows_non_agent_tools (Edit): exits 0" "0" "$_exit_code"
assert_ne "test_allows_non_agent_tools (Edit): no deny in stdout" '"permissionDecision": "deny"' "$_stdout"

# ============================================================
# test_handles_null_tool_input
# Agent call with null/missing tool_input must fail-open (exit 0, no deny).
# The hook is defensive — malformed input must not cause blocking.
# ============================================================
echo "--- test_handles_null_tool_input ---"

# Case 1: tool_input is null
_INPUT='{"tool_name":"Agent","tool_input":null}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_handles_null_tool_input (null input): exits 0" "0" "$_exit_code"
assert_ne "test_handles_null_tool_input (null input): no deny" '"permissionDecision": "deny"' "$_stdout"

# Case 2: tool_input key is missing entirely
_INPUT='{"tool_name":"Agent"}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_handles_null_tool_input (missing tool_input): exits 0" "0" "$_exit_code"
assert_ne "test_handles_null_tool_input (missing tool_input): no deny" '"permissionDecision": "deny"' "$_stdout"

# Case 3: Agent with isolation set to a non-worktree value — must be allowed
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"none","prompt":"test"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_handles_null_tool_input (non-worktree isolation): exits 0" "0" "$_exit_code"
assert_ne "test_handles_null_tool_input (non-worktree isolation): no deny" '"permissionDecision": "deny"' "$_stdout"

# ============================================================
# Summary
# ============================================================
print_summary
