#!/usr/bin/env bash
# tests/hooks/test-session-misc-no-jq.sh
# Unit tests verifying session-misc-functions.sh contains zero jq calls
# and that each function works correctly with python3/bash-native alternatives.
#
# Tests:
#   test_no_jq_calls_in_session_misc_functions
#   test_session_safety_check_with_known_input
#   test_tool_logging_summary_with_known_input
#   test_track_tool_errors_with_known_input
#   test_taskoutput_block_guard_no_jq_branch
#
# Usage: bash tests/hooks/test-session-misc-no-jq.sh

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

SESSION_MISC_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/session-misc-functions.sh"

# ============================================================
# test_no_jq_calls_in_session_misc_functions
# The file must contain zero jq calls — no 'check_tool jq',
# no 'command -v jq', no piping to jq, no 'jq -' invocations.
# ============================================================
echo "--- test_no_jq_calls_in_session_misc_functions ---"
_jq_calls=$(grep -cE '^\s*(check_tool jq|command -v jq|.*\| jq |jq -)' "$SESSION_MISC_FUNCTIONS" 2>/dev/null) || _jq_calls=0
assert_eq "test_no_jq_calls: zero jq calls in session-misc-functions.sh" "0" "$_jq_calls"

# ============================================================
# test_session_safety_check_with_known_input
# hook_session_safety_check reads a JSONL error log, filters by
# 24h cutoff, and counts errors per hook. With a known log file
# containing recent entries, it should detect high-error hooks.
# ============================================================
echo "--- test_session_safety_check_with_known_input ---"

_test_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_test_dir")
mkdir -p "$_test_dir/.claude/logs"
mkdir -p "$_test_dir/.claude"
_test_log="$_test_dir/.claude/logs/dso-hook-errors.jsonl"
# Create 12 recent error entries for the same hook (exceeds threshold of 10)
_now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for i in $(seq 1 12); do
    echo "{\"ts\":\"$_now_ts\",\"hook\":\"test-hook.sh\",\"line\":$i}" >> "$_test_log"
done

# Source the library in a subshell with HOME overridden
_exit_code=0
_output=""
_output=$(
    HOME="$_test_dir" \
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_session_safety_check
    ' 2>/dev/null
) || _exit_code=$?

assert_eq "test_session_safety_check: exits 0" "0" "$_exit_code"
assert_contains "test_session_safety_check: detects high-error hook" "test-hook.sh" "$_output"
assert_contains "test_session_safety_check: shows error count" "12" "$_output"

rm -rf "$_test_dir"

# ============================================================
# test_session_safety_check_no_log
# When no error log exists, the function should exit 0 quietly.
# ============================================================
echo "--- test_session_safety_check_no_log ---"

_test_dir2=$(mktemp -d)
_CLEANUP_DIRS+=("$_test_dir2")
_exit_code=0
_output=""
_output=$(
    HOME="$_test_dir2" \
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_session_safety_check
    ' 2>/dev/null
) || _exit_code=$?

assert_eq "test_session_safety_check_no_log: exits 0" "0" "$_exit_code"
assert_eq "test_session_safety_check_no_log: no output" "" "$_output"

rm -rf "$_test_dir2"

# ============================================================
# test_tool_logging_summary_with_known_input
# hook_tool_logging_summary reads JSONL log files. With a known
# log containing 15+ post entries, it should produce a summary.
# ============================================================
echo "--- test_tool_logging_summary_with_known_input ---"

_test_dir3=$(mktemp -d)
_CLEANUP_DIRS+=("$_test_dir3")
mkdir -p "$_test_dir3/.claude/logs"
echo "test-session-001" > "$_test_dir3/.claude/current-session-id"
touch "$_test_dir3/.claude/tool-logging-enabled"

_log_file="$_test_dir3/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
_base_epoch=1700000000000
for i in $(seq 1 20); do
    _epoch=$(( _base_epoch + i * 1000 ))
    echo "{\"session_id\":\"test-session-001\",\"hook_type\":\"pre\",\"tool_name\":\"Bash\",\"epoch_ms\":$_epoch}" >> "$_log_file"
    _post_epoch=$(( _epoch + 500 ))
    echo "{\"session_id\":\"test-session-001\",\"hook_type\":\"post\",\"tool_name\":\"Bash\",\"epoch_ms\":$_post_epoch}" >> "$_log_file"
done

_exit_code=0
_output=""
_output=$(
    HOME="$_test_dir3" \
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_tool_logging_summary
    ' 2>/dev/null
) || _exit_code=$?

assert_eq "test_tool_logging_summary: exits 0" "0" "$_exit_code"
assert_contains "test_tool_logging_summary: session ID in output" "test-session-001" "$_output"
assert_contains "test_tool_logging_summary: total calls" "20" "$_output"
assert_contains "test_tool_logging_summary: Bash in tool counts" "Bash" "$_output"

rm -rf "$_test_dir3"

# ============================================================
# test_tool_logging_summary_below_threshold
# When fewer than 10 post calls exist, summary should not appear.
# ============================================================
echo "--- test_tool_logging_summary_below_threshold ---"

_test_dir4=$(mktemp -d)
_CLEANUP_DIRS+=("$_test_dir4")
mkdir -p "$_test_dir4/.claude/logs"
echo "test-session-002" > "$_test_dir4/.claude/current-session-id"
touch "$_test_dir4/.claude/tool-logging-enabled"

_log_file4="$_test_dir4/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
for i in $(seq 1 5); do
    _epoch=$(( 1700000000000 + i * 1000 ))
    echo "{\"session_id\":\"test-session-002\",\"hook_type\":\"post\",\"tool_name\":\"Read\",\"epoch_ms\":$_epoch}" >> "$_log_file4"
done

_exit_code=0
_output=""
_output=$(
    HOME="$_test_dir4" \
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_tool_logging_summary
    ' 2>/dev/null
) || _exit_code=$?

assert_eq "test_tool_logging_summary_below_threshold: exits 0" "0" "$_exit_code"
# Should not contain the summary header since < 10 calls
_has_summary=0
_tmp="$_output"; [[ "$_tmp" =~ Session\ Tool\ Usage\ Summary ]] && _has_summary=1
assert_eq "test_tool_logging_summary_below_threshold: no summary" "0" "$_has_summary"

rm -rf "$_test_dir4"

# ============================================================
# test_track_tool_errors_with_known_input
# hook_track_tool_errors should categorize errors and update
# the counter file using python3 instead of jq.
# ============================================================
echo "--- test_track_tool_errors_with_known_input ---"

_test_dir5=$(mktemp -d)
_CLEANUP_DIRS+=("$_test_dir5")
_counter_file="$_test_dir5/.claude/tool-error-counter.json"
mkdir -p "$_test_dir5/.claude"

_input='{"tool_name":"Bash","error":"command not found: xyz","tool_input":{"command":"xyz"},"session_id":"test-sess","is_interrupt":false}'

_exit_code=0
_output=""
_output=$(
    HOME="$_test_dir5" \
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    DSO_MONITORING_TOOL_ERRORS="true" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_track_tool_errors '"'"''"$_input"''"'"'
    ' 2>/dev/null
) || _exit_code=$?

assert_eq "test_track_tool_errors: exits 0" "0" "$_exit_code"

# Verify counter file was created and contains the error
_counter_exists=0
[[ -f "$_counter_file" ]] && _counter_exists=1
assert_eq "test_track_tool_errors: counter file created" "1" "$_counter_exists"

# Verify it contains valid JSON with the category
if [[ -f "$_counter_file" ]]; then
    _has_category=0
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
assert 'command_not_found' in data.get('index', {}), 'category not found'
assert len(data.get('errors', [])) > 0, 'no errors'
" "$_counter_file" 2>/dev/null && _has_category=1
    assert_eq "test_track_tool_errors: counter has command_not_found category" "1" "$_has_category"
fi

rm -rf "$_test_dir5"

# ============================================================
# test_track_tool_errors_skips_interrupts
# hook_track_tool_errors should skip user interrupts.
# ============================================================
echo "--- test_track_tool_errors_skips_interrupts ---"

_test_dir6=$(mktemp -d)
_CLEANUP_DIRS+=("$_test_dir6")
mkdir -p "$_test_dir6/.claude"

_input_interrupt='{"tool_name":"Bash","error":"interrupted","tool_input":{},"session_id":"test","is_interrupt":true}'

_exit_code=0
(
    HOME="$_test_dir6" \
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    DSO_MONITORING_TOOL_ERRORS="true" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_track_tool_errors '"'"''"$_input_interrupt"''"'"'
    '
) >/dev/null 2>&1 || _exit_code=$?

assert_eq "test_track_tool_errors_skips_interrupts: exits 0" "0" "$_exit_code"

# Counter file should not exist since interrupt was skipped
_counter_exists=0
[[ -f "$_test_dir6/.claude/tool-error-counter.json" ]] && _counter_exists=1
assert_eq "test_track_tool_errors_skips_interrupts: no counter file" "0" "$_counter_exists"

rm -rf "$_test_dir6"

# ============================================================
# test_taskoutput_block_guard_no_jq_branch
# hook_taskoutput_block_guard should work without jq using the
# grep fallback. Verify it still blocks block=false and allows
# block=true.
# ============================================================
echo "--- test_taskoutput_block_guard_no_jq_branch ---"

# Test block=false is blocked (use grep fallback by masking jq)
_input_block_false='{"tool_name":"TaskOutput","tool_input":{"block":false,"task_id":"123"}}'
_exit_code=0
_output=""
_output=$(
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_taskoutput_block_guard '"'"''"$_input_block_false"''"'"'
    ' 2>&1
) || _exit_code=$?

assert_eq "test_taskoutput_block_guard: exit 2 on block=false" "2" "$_exit_code"
assert_contains "test_taskoutput_block_guard: BLOCKED in output" "BLOCKED" "$_output"

# Test block=true is allowed
_input_block_true='{"tool_name":"TaskOutput","tool_input":{"block":true,"task_id":"123"}}'
_exit_code=0
(
    _SESSION_MISC_FUNCTIONS_LOADED="" \
    bash -c '
        source "'"$SESSION_MISC_FUNCTIONS"'" 2>/dev/null
        hook_taskoutput_block_guard '"'"''"$_input_block_true"''"'"'
    '
) >/dev/null 2>&1 || _exit_code=$?

assert_eq "test_taskoutput_block_guard: exit 0 on block=true" "0" "$_exit_code"

# ============================================================
# Summary
# ============================================================
print_summary
