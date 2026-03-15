#!/usr/bin/env bash
# Tests worktree-isolation-guard.sh (Agent isolation block) — see test-worktree-guard.sh for worktree-edit-guard.sh (Edit/Write block)
#
# worktree-isolation-guard.sh is a PreToolUse hook that blocks Agent tool calls
# that specify isolation: "worktree". Worktree isolation breaks shared state
# (artifacts dir, review findings, diff hashes).
#
# Tests:
#   test_blocks_agent_with_worktree_isolation
#   test_allows_agent_without_isolation
#   test_allows_non_agent_tools
#   test_handles_null_tool_input
#
# Usage: bash lockpick-workflow/tests/hooks/test-worktree-isolation-guard.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

HOOK="$REPO_ROOT/lockpick-workflow/hooks/worktree-isolation-guard.sh"

# Helper: run hook with given JSON input, return exit code via echo
run_hook_exit() {
    local input="$1"
    local exit_code=0
    printf '%s' "$input" | bash "$HOOK" >/dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Helper: run hook with given JSON input, return stdout
run_hook_stdout() {
    local input="$1"
    printf '%s' "$input" | bash "$HOOK" 2>/dev/null || true
}

# ============================================================
# test_blocks_agent_with_worktree_isolation
# Agent tool call with isolation: "worktree" must be denied.
# The hook outputs JSON with permissionDecision: deny and exits 0.
# ============================================================
echo "--- test_blocks_agent_with_worktree_isolation ---"
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","prompt":"do something"}}'
_exit_code=$(run_hook_exit "$_INPUT")
_stdout=$(run_hook_stdout "$_INPUT")
assert_eq "test_blocks_agent_with_worktree_isolation: exits 0" "0" "$_exit_code"
assert_contains "test_blocks_agent_with_worktree_isolation: stdout contains permissionDecision" "permissionDecision" "$_stdout"
assert_contains "test_blocks_agent_with_worktree_isolation: permissionDecision is deny" '"permissionDecision": "deny"' "$_stdout"

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
