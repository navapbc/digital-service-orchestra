#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-dispatcher-tool-logging-fast-path.sh
# Tests that pre-all.sh and post-all.sh skip tool-logging subprocess when
# the tool-logging-enabled flag file is absent (fast-path optimization).
#
# Tests:
#   test_pre_all_skips_tool_logging_when_disabled
#   test_post_all_skips_tool_logging_when_disabled
#   test_pre_all_runs_tool_logging_when_enabled
#   test_post_all_runs_tool_logging_when_enabled
#   test_post_functions_defense_in_depth_pre
#   test_post_functions_defense_in_depth_post
#
# Usage: bash lockpick-workflow/tests/hooks/test-dispatcher-tool-logging-fast-path.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

PRE_ALL="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-all.sh"
POST_ALL="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-all.sh"
POST_FUNCTIONS="$REPO_ROOT/lockpick-workflow/hooks/lib/post-functions.sh"

LOGGING_FLAG="$HOME/.claude/tool-logging-enabled"
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"}}'

# Save and remove flag file for disabled-logging tests
_SAVED_FLAG=false
if [[ -f "$LOGGING_FLAG" ]]; then
    _SAVED_FLAG=true
    rm -f "$LOGGING_FLAG"
fi

# ============================================================
# test_pre_all_skips_tool_logging_when_disabled
# Verify pre-all.sh checks the flag before calling tool-logging.sh
# ============================================================
echo "--- test_pre_all_skips_tool_logging_when_disabled ---"
_has_check=0
grep -q 'tool-logging-enabled' "$PRE_ALL" && _has_check=1
assert_eq "test_pre_all_skips_tool_logging_when_disabled: has flag check" "1" "$_has_check"

# Verify it exits 0 when disabled
_exit=0
echo "$INPUT" | bash "$PRE_ALL" >/dev/null 2>/dev/null || _exit=$?
assert_eq "test_pre_all_skips_tool_logging_when_disabled: exits 0" "0" "$_exit"

# ============================================================
# test_post_all_skips_tool_logging_when_disabled
# Verify post-all.sh checks the flag before calling hook_tool_logging_post
# ============================================================
echo "--- test_post_all_skips_tool_logging_when_disabled ---"
_has_check=0
grep -q 'tool-logging-enabled' "$POST_ALL" && _has_check=1
assert_eq "test_post_all_skips_tool_logging_when_disabled: has flag check" "1" "$_has_check"

# Verify it exits 0 when disabled
_exit=0
echo "$INPUT" | bash "$POST_ALL" >/dev/null 2>/dev/null || _exit=$?
assert_eq "test_post_all_skips_tool_logging_when_disabled: exits 0" "0" "$_exit"

# ============================================================
# test_post_functions_defense_in_depth_pre
# Verify hook_tool_logging_pre in post-functions.sh has its own flag check
# ============================================================
echo "--- test_post_functions_defense_in_depth_pre ---"
# Check that post-functions.sh mentions tool-logging-enabled at least twice
# (once for hook_tool_logging_pre, once for hook_tool_logging_post)
_count=0
_count=$(grep -c 'tool-logging-enabled' "$POST_FUNCTIONS")
_has_two=0
[[ "$_count" -ge 2 ]] && _has_two=1
assert_eq "test_post_functions_defense_in_depth: at least 2 flag checks" "1" "$_has_two"

# ============================================================
# test_post_functions_defense_in_depth_post
# Verify hook_tool_logging_post in post-functions.sh has its own flag check
# ============================================================
echo "--- test_post_functions_defense_in_depth_post ---"
# Already verified by count above; verify the function-level early returns
_has_pre_check=0
# Look for the flag check pattern near hook_tool_logging_pre function
grep -A5 'hook_tool_logging_pre' "$POST_FUNCTIONS" | grep -q 'tool-logging-enabled' && _has_pre_check=1
assert_eq "test_post_functions_defense_in_depth_post: hook_tool_logging_pre has flag check" "1" "$_has_pre_check"

_has_post_check=0
grep -A5 'hook_tool_logging_post' "$POST_FUNCTIONS" | grep -q 'tool-logging-enabled' && _has_post_check=1
assert_eq "test_post_functions_defense_in_depth_post: hook_tool_logging_post has flag check" "1" "$_has_post_check"

# ============================================================
# test_pre_all_runs_tool_logging_when_enabled
# Verify pre-all.sh still works when logging IS enabled
# ============================================================
echo "--- test_pre_all_runs_tool_logging_when_enabled ---"
mkdir -p "$(dirname "$LOGGING_FLAG")"
touch "$LOGGING_FLAG"

_exit=0
echo "$INPUT" | bash "$PRE_ALL" >/dev/null 2>/dev/null || _exit=$?
assert_eq "test_pre_all_runs_tool_logging_when_enabled: exits 0" "0" "$_exit"

# ============================================================
# test_post_all_runs_tool_logging_when_enabled
# Verify post-all.sh still works when logging IS enabled
# ============================================================
echo "--- test_post_all_runs_tool_logging_when_enabled ---"
_exit=0
echo "$INPUT" | bash "$POST_ALL" >/dev/null 2>/dev/null || _exit=$?
assert_eq "test_post_all_runs_tool_logging_when_enabled: exits 0" "0" "$_exit"

# Cleanup: restore flag file state
rm -f "$LOGGING_FLAG"
if [[ "$_SAVED_FLAG" == "true" ]]; then
    touch "$LOGGING_FLAG"
fi

print_summary
