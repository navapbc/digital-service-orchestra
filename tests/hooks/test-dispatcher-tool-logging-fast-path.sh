#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-dispatcher-tool-logging-fast-path.sh
# Tests that tool-logging has been removed from dispatchers (optimization)
# and that the function-level defense-in-depth checks remain in post-functions.sh.
#
# Tests:
#   test_pre_all_exits_0
#   test_post_all_exits_0_no_logging
#   test_post_functions_defense_in_depth_pre
#   test_post_functions_defense_in_depth_post
#
# Usage: bash lockpick-workflow/tests/hooks/test-dispatcher-tool-logging-fast-path.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

PRE_ALL="$PLUGIN_ROOT/hooks/dispatchers/pre-all.sh"
POST_ALL="$PLUGIN_ROOT/hooks/dispatchers/post-all.sh"
POST_FUNCTIONS="$PLUGIN_ROOT/hooks/lib/post-functions.sh"

INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"}}'

# ============================================================
# test_pre_all_exits_0
# Verify pre-all.sh exits 0 cleanly
# ============================================================
echo "--- test_pre_all_exits_0 ---"
_exit=0
echo "$INPUT" | bash "$PRE_ALL" >/dev/null 2>/dev/null || _exit=$?
assert_eq "test_pre_all_exits_0: exits 0" "0" "$_exit"

# ============================================================
# test_post_all_exits_0_no_logging
# After optimization, post-all.sh is a no-op. Verify it exits 0.
# ============================================================
echo "--- test_post_all_exits_0_no_logging ---"
_exit=0
echo "$INPUT" | bash "$POST_ALL" >/dev/null 2>/dev/null || _exit=$?
assert_eq "test_post_all_exits_0_no_logging: exits 0" "0" "$_exit"

# ============================================================
# test_post_functions_defense_in_depth_pre
# Verify hook_tool_logging_pre in post-functions.sh still has its own flag check
# (function still exists for backward compat, even though dispatchers don't call it)
# ============================================================
echo "--- test_post_functions_defense_in_depth_pre ---"
_count="$(grep -c 'tool-logging-enabled' "$POST_FUNCTIONS")" || _count="0"
_has_two=0
[[ "$_count" -ge 2 ]] && _has_two=1
assert_eq "test_post_functions_defense_in_depth: at least 2 flag checks" "1" "$_has_two"

# ============================================================
# test_post_functions_defense_in_depth_post
# Verify hook_tool_logging_post in post-functions.sh still has its own flag check
# ============================================================
echo "--- test_post_functions_defense_in_depth_post ---"
_has_pre_check=0
grep -A5 'hook_tool_logging_pre' "$POST_FUNCTIONS" | grep -q 'tool-logging-enabled' && _has_pre_check=1
assert_eq "test_post_functions_defense_in_depth_post: hook_tool_logging_pre has flag check" "1" "$_has_pre_check"

_has_post_check=0
grep -A5 'hook_tool_logging_post' "$POST_FUNCTIONS" | grep -q 'tool-logging-enabled' && _has_post_check=1
assert_eq "test_post_functions_defense_in_depth_post: hook_tool_logging_post has flag check" "1" "$_has_post_check"

print_summary
