#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-plugin-load.sh
# Integration test: verifies 'claude --plugin-dir lockpick-workflow' loads successfully.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-plugin-load.sh
#
# Exit codes:
#   0 — test passed (or skipped because claude binary is unavailable)
#   1 — test failed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

PLUGIN_DIR="$REPO_ROOT/lockpick-workflow"

# Skip guard: if claude binary is not in PATH, print SKIP and exit 0.
# This ensures CI environments without claude installed are not blocked.
if ! command -v claude &>/dev/null; then
    echo "SKIP: claude binary not available"
    exit 0
fi

# Skip guard: if running inside a Claude Code session, nested invocation is blocked.
# Unset CLAUDECODE to allow the invocation, or skip if we cannot safely proceed.
# The CLAUDECODE env var is set by Claude Code to detect nested sessions.
if [[ -n "${CLAUDECODE:-}" ]]; then
    echo "SKIP: running inside a Claude Code session — unset CLAUDECODE to run this test"
    exit 0
fi

# test_plugin_loads_via_claude_plugin_dir
# Invoke 'claude --plugin-dir <path> --version' and assert:
#   1. Exit code is 0
#   2. Output contains no error strings (no "error" or "Error" or "ERROR" in combined output)
# Note: --print-config was removed from the claude CLI; --version validates plugin
# loading without making API calls.
output=$(claude --plugin-dir "$PLUGIN_DIR" --version 2>&1)
exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
    actual_exit="0"
else
    actual_exit="$exit_code"
fi
assert_eq "test_plugin_loads_via_claude_plugin_dir: exit code" "0" "$actual_exit"

# Assert no error output (case-insensitive check for "error" in output)
if echo "$output" | grep -qi "error"; then
    assert_eq "test_plugin_loads_via_claude_plugin_dir: no error output" "no_error" "error_found"
else
    assert_eq "test_plugin_loads_via_claude_plugin_dir: no error output" "no_error" "no_error"
fi

print_summary
