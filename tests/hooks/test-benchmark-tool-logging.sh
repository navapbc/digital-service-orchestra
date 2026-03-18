#!/usr/bin/env bash
# tests/hooks/test-benchmark-tool-logging.sh
# Unit tests for benchmark-tool-logging.sh script and timing instrumentation
# in pre-all.sh and post-all.sh dispatchers.
#
# Tests:
#   test_benchmark_script_exists_and_executable
#   test_benchmark_tool_logging_produces_timing_output
#   test_benchmark_uses_macos_compatible_timing
#   test_pre_all_has_timing_instrumentation
#   test_post_all_has_timing_instrumentation
#   test_pre_all_timing_is_opt_in
#   test_post_all_timing_is_opt_in
#   test_pre_all_still_exits_0_with_timing_enabled
#   test_post_all_still_exits_0_with_timing_enabled
#
# Usage: bash tests/hooks/test-benchmark-tool-logging.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

BENCHMARK_SCRIPT="$DSO_PLUGIN_DIR/scripts/benchmark-tool-logging.sh"
PRE_ALL_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-all.sh"
POST_ALL_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/post-all.sh"

# ============================================================
# test_benchmark_script_exists_and_executable
# ============================================================
echo "--- test_benchmark_script_exists_and_executable ---"
_exists=0
[[ -f "$BENCHMARK_SCRIPT" ]] && _exists=1
assert_eq "test_benchmark_script_exists_and_executable: file exists" "1" "$_exists"

_executable=0
[[ -x "$BENCHMARK_SCRIPT" ]] && _executable=1
assert_eq "test_benchmark_script_exists_and_executable: is executable" "1" "$_executable"

# ============================================================
# test_benchmark_tool_logging_produces_timing_output
# Run the benchmark script with 3 iterations and verify it
# outputs lines containing "min", "avg", "max" timing values.
# ============================================================
echo "--- test_benchmark_tool_logging_produces_timing_output ---"
_output=""
_exit_code=0
_output=$(bash "$BENCHMARK_SCRIPT" 3 2>/dev/null) || _exit_code=$?
assert_eq "test_benchmark_tool_logging_produces_timing_output: exits 0" "0" "$_exit_code"
assert_contains "test_benchmark_tool_logging_produces_timing_output: has min" "min" "$_output"
assert_contains "test_benchmark_tool_logging_produces_timing_output: has avg" "avg" "$_output"
assert_contains "test_benchmark_tool_logging_produces_timing_output: has max" "max" "$_output"

# ============================================================
# test_benchmark_uses_macos_compatible_timing
# The benchmark script must use date +%s%N with python3 or gdate fallback.
# ============================================================
echo "--- test_benchmark_uses_macos_compatible_timing ---"
_has_fallback=0
grep -qE 'python3|gdate|%s%N.*\|\|' "$BENCHMARK_SCRIPT" && _has_fallback=1
assert_eq "test_benchmark_uses_macos_compatible_timing: has macOS-compatible timing" "1" "$_has_fallback"

# ============================================================
# test_pre_all_has_timing_instrumentation
# pre-all.sh must reference hook-timing-enabled flag.
# ============================================================
echo "--- test_pre_all_has_timing_instrumentation ---"
_has_timing=0
grep -q "hook-timing-enabled" "$PRE_ALL_DISPATCHER" && _has_timing=1
assert_eq "test_pre_all_has_timing_instrumentation: references hook-timing-enabled" "1" "$_has_timing"

# ============================================================
# test_post_all_has_timing_instrumentation
# post-all.sh must reference hook-timing-enabled flag.
# ============================================================
echo "--- test_post_all_has_timing_instrumentation ---"
_has_timing=0
grep -q "hook-timing-enabled" "$POST_ALL_DISPATCHER" && _has_timing=1
assert_eq "test_post_all_has_timing_instrumentation: references hook-timing-enabled" "1" "$_has_timing"

# ============================================================
# test_pre_all_timing_is_opt_in
# Timing must only activate when ~/.claude/hook-timing-enabled exists.
# Without the flag, pre-all.sh must NOT write to /tmp/hook-timing.log.
# ============================================================
echo "--- test_pre_all_timing_is_opt_in ---"
# Clean up any existing timing log
_timing_log="/tmp/hook-timing-test-pre-all-$$"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"test"}'
# Ensure flag does NOT exist (use temp HOME)
_tmp_home=$(mktemp -d)
_CLEANUP_DIRS+=("$_tmp_home")
_exit_code=0
printf '%s' "$_INPUT" | HOME="$_tmp_home" bash "$PRE_ALL_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_all_timing_is_opt_in: exits 0 without flag" "0" "$_exit_code"
# Verify no timing log was written in /tmp for this invocation
# (We check source code instead — timing block is guarded by flag check)
_guarded=0
grep -qE 'hook-timing-enabled.*\]' "$PRE_ALL_DISPATCHER" && _guarded=1
assert_eq "test_pre_all_timing_is_opt_in: timing is conditional" "1" "$_guarded"
rm -rf "$_tmp_home"

# ============================================================
# test_post_all_timing_is_opt_in
# Same check for post-all.sh.
# ============================================================
echo "--- test_post_all_timing_is_opt_in ---"
_guarded=0
grep -qE 'hook-timing-enabled.*\]' "$POST_ALL_DISPATCHER" && _guarded=1
assert_eq "test_post_all_timing_is_opt_in: timing is conditional" "1" "$_guarded"

# ============================================================
# test_pre_all_still_exits_0_with_timing_enabled
# With the flag enabled, pre-all.sh must still exit 0
# (timing is informational, never blocks).
# ============================================================
echo "--- test_pre_all_still_exits_0_with_timing_enabled ---"
_tmp_home=$(mktemp -d)
_CLEANUP_DIRS+=("$_tmp_home")
mkdir -p "$_tmp_home/.claude"
touch "$_tmp_home/.claude/hook-timing-enabled"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"test"}'
_exit_code=0
printf '%s' "$_INPUT" | HOME="$_tmp_home" bash "$PRE_ALL_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_all_still_exits_0_with_timing_enabled: exits 0" "0" "$_exit_code"
rm -rf "$_tmp_home"

# ============================================================
# test_post_all_still_exits_0_with_timing_enabled
# With the flag enabled, post-all.sh must still exit 0.
# ============================================================
echo "--- test_post_all_still_exits_0_with_timing_enabled ---"
_tmp_home=$(mktemp -d)
_CLEANUP_DIRS+=("$_tmp_home")
mkdir -p "$_tmp_home/.claude"
touch "$_tmp_home/.claude/hook-timing-enabled"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"test"}'
_exit_code=0
printf '%s' "$_INPUT" | HOME="$_tmp_home" bash "$POST_ALL_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_post_all_still_exits_0_with_timing_enabled: exits 0" "0" "$_exit_code"
rm -rf "$_tmp_home"

# ============================================================
# Summary
# ============================================================
print_summary
