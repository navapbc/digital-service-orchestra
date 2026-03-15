#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-exit-144-forensics.sh
# Tests for exit-144 forensic logger:
#   Part 1 (Batch 1): PreToolUse dispatcher records Bash start timestamps.
#   Part 2 (Batch 2): PostToolUse forensic logger writes JSONL on exit 144.
#
# Validates:
#   - Bash tool calls create a command-hash-keyed timestamp file (bash-start-ts-XXXXXXXX)
#   - Non-Bash tool calls do NOT create timestamp files
#   - Timestamp value is a numeric millisecond timestamp
#   - Exit 144 triggers JSONL forensic log entry
#   - Non-144 exits produce zero file I/O
#   - JSONL entries are valid JSON with required fields
#   - Missing start timestamp yields elapsed_s=-1
#   - Boundary classification: 69999ms=cancellation, 70000ms=timeout
#   - Missing exit_code field is handled gracefully

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-bash.sh"
POST_HOOK="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-bash.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ============================================================
# test_pre_bash_records_start_timestamp
# A Bash tool call should create a bash-start-ts-<hash> file
# in the artifacts directory with a numeric timestamp value.
# ============================================================
_TEST1_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST1_DIR")
_TEST1_COMMAND="echo hello world"
_TEST1_HASH=$(echo -n "$_TEST1_COMMAND" | hash_stdin | cut -c1-8)
_TEST1_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}'

# Run the dispatcher with isolated artifacts dir
_TEST1_EXIT=0
echo "$_TEST1_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST1_DIR" bash "$HOOK" 2>/dev/null || _TEST1_EXIT=$?

# Check that the timestamp file exists
_TEST1_TS_FILE="$_TEST1_DIR/bash-start-ts-${_TEST1_HASH}"
if [[ -f "$_TEST1_TS_FILE" ]]; then
    _TEST1_FILE_EXISTS="yes"
else
    _TEST1_FILE_EXISTS="no"
fi
assert_eq "test_pre_bash_records_start_timestamp: file exists" "yes" "$_TEST1_FILE_EXISTS"

# Check that the timestamp value is numeric
if [[ -f "$_TEST1_TS_FILE" ]]; then
    _TEST1_TS_VALUE=$(cat "$_TEST1_TS_FILE")
    if [[ "$_TEST1_TS_VALUE" =~ ^[0-9]+$ ]]; then
        _TEST1_IS_NUMERIC="yes"
    else
        _TEST1_IS_NUMERIC="no"
    fi
else
    _TEST1_IS_NUMERIC="no"
fi
assert_eq "test_pre_bash_records_start_timestamp: value is numeric" "yes" "$_TEST1_IS_NUMERIC"

rm -rf "$_TEST1_DIR"

# ============================================================
# test_pre_non_bash_does_not_create_timestamp
# A non-Bash tool call (e.g., Read) should NOT create any
# bash-start-ts-* files in the artifacts directory.
# ============================================================
_TEST2_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST2_DIR")
_TEST2_INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"}}'

# Run the dispatcher with isolated artifacts dir
# Note: pre-bash.sh is the Bash dispatcher — it only runs for Bash tool calls.
# When invoked with non-Bash input, the hooks still run but should not create timestamp files.
_TEST2_EXIT=0
echo "$_TEST2_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST2_DIR" bash "$HOOK" 2>/dev/null || _TEST2_EXIT=$?

# Check that NO bash-start-ts-* files exist
_TEST2_TS_FILES=$(ls "$_TEST2_DIR"/bash-start-ts-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "test_pre_non_bash_does_not_create_timestamp: no ts files" "0" "$_TEST2_TS_FILES"

rm -rf "$_TEST2_DIR"

# ============================================================
# test_pre_bash_uses_command_hash_keyed_filename
# Two different commands should create different timestamp files.
# ============================================================
_TEST3_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST3_DIR")
_TEST3_CMD_A="git status"
_TEST3_CMD_B="make test"
_TEST3_HASH_A=$(echo -n "$_TEST3_CMD_A" | hash_stdin | cut -c1-8)
_TEST3_HASH_B=$(echo -n "$_TEST3_CMD_B" | hash_stdin | cut -c1-8)
_TEST3_INPUT_A='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
_TEST3_INPUT_B='{"tool_name":"Bash","tool_input":{"command":"make test"}}'

echo "$_TEST3_INPUT_A" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST3_DIR" bash "$HOOK" 2>/dev/null || true
echo "$_TEST3_INPUT_B" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST3_DIR" bash "$HOOK" 2>/dev/null || true

# Both files should exist with different hash-keyed names
_TEST3_FILE_A_EXISTS="no"
_TEST3_FILE_B_EXISTS="no"
[[ -f "$_TEST3_DIR/bash-start-ts-${_TEST3_HASH_A}" ]] && _TEST3_FILE_A_EXISTS="yes"
[[ -f "$_TEST3_DIR/bash-start-ts-${_TEST3_HASH_B}" ]] && _TEST3_FILE_B_EXISTS="yes"

assert_eq "test_pre_bash_uses_command_hash_keyed_filename: file A exists" "yes" "$_TEST3_FILE_A_EXISTS"
assert_eq "test_pre_bash_uses_command_hash_keyed_filename: file B exists" "yes" "$_TEST3_FILE_B_EXISTS"

# Hashes should be different
assert_ne "test_pre_bash_uses_command_hash_keyed_filename: different hashes" "$_TEST3_HASH_A" "$_TEST3_HASH_B"

rm -rf "$_TEST3_DIR"

# ============================================================
# Part 2: PostToolUse forensic logger tests
# ============================================================

# ============================================================
# test_post_bash_logs_forensic_entry_on_exit_144
# When exit_code=144 and a start timestamp exists, a JSONL entry
# should be written to exit-144-forensics.jsonl with correct fields.
# ============================================================
_TEST4_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST4_DIR")
_TEST4_COMMAND="make test-unit-only"
_TEST4_HASH=$(echo -n "$_TEST4_COMMAND" | hash_stdin | cut -c1-8)

# Simulate a start timestamp 80 seconds ago (80000ms → timeout)
_TEST4_NOW_MS=$(python3 -c 'import time;print(int(time.time()*1e3))')
_TEST4_START_MS=$(( _TEST4_NOW_MS - 80000 ))
echo "$_TEST4_START_MS" > "$_TEST4_DIR/bash-start-ts-${_TEST4_HASH}"

_TEST4_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only"},"tool_response":{"exit_code":144}}'

echo "$_TEST4_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST4_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST4_JSONL="$_TEST4_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST4_JSONL" ]]; then
    _TEST4_FILE_EXISTS="yes"
else
    _TEST4_FILE_EXISTS="no"
fi
assert_eq "test_post_bash_logs_forensic_entry_on_exit_144: jsonl file created" "yes" "$_TEST4_FILE_EXISTS"

# Verify cause is "timeout" (80s > 70s threshold)
if [[ -f "$_TEST4_JSONL" ]]; then
    _TEST4_CAUSE=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('cause',''))" < "$_TEST4_JSONL")
else
    _TEST4_CAUSE=""
fi
assert_eq "test_post_bash_logs_forensic_entry_on_exit_144: cause is timeout" "timeout" "$_TEST4_CAUSE"

rm -rf "$_TEST4_DIR"

# ============================================================
# test_post_bash_no_file_io_on_non_144
# When exit_code != 144, no JSONL file should be created.
# ============================================================
_TEST5_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST5_DIR")
_TEST5_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo ok"},"tool_response":{"exit_code":0}}'

echo "$_TEST5_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST5_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST5_JSONL="$_TEST5_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST5_JSONL" ]]; then
    _TEST5_NO_FILE="no"
else
    _TEST5_NO_FILE="yes"
fi
assert_eq "test_post_bash_no_file_io_on_non_144: no jsonl file" "yes" "$_TEST5_NO_FILE"

rm -rf "$_TEST5_DIR"

# ============================================================
# test_forensic_entry_is_valid_json
# The JSONL entry should be valid JSON with all required fields:
# timestamp, command, elapsed_s, cause, cwd
# ============================================================
_TEST6_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST6_DIR")
_TEST6_COMMAND="poetry run pytest"
_TEST6_HASH=$(echo -n "$_TEST6_COMMAND" | hash_stdin | cut -c1-8)

# Simulate 75s elapsed (timeout)
_TEST6_NOW_MS=$(python3 -c 'import time;print(int(time.time()*1e3))')
_TEST6_START_MS=$(( _TEST6_NOW_MS - 75000 ))
echo "$_TEST6_START_MS" > "$_TEST6_DIR/bash-start-ts-${_TEST6_HASH}"

_TEST6_INPUT='{"tool_name":"Bash","tool_input":{"command":"poetry run pytest"},"tool_response":{"exit_code":144}}'

echo "$_TEST6_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST6_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST6_JSONL="$_TEST6_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST6_JSONL" ]]; then
    # Validate all required fields exist and entry is valid JSON
    _TEST6_VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.readline())
    required = ['timestamp', 'command', 'elapsed_s', 'cause', 'cwd']
    missing = [k for k in required if k not in d]
    if missing:
        print('missing:' + ','.join(missing))
    elif not isinstance(d['elapsed_s'], (int, float)):
        print('elapsed_s not numeric')
    elif d['cause'] not in ('timeout', 'cancellation', 'unknown'):
        print('invalid cause: ' + str(d['cause']))
    else:
        print('valid')
except Exception as e:
    print('error:' + str(e))
" < "$_TEST6_JSONL")
else
    _TEST6_VALID="file_missing"
fi
assert_eq "test_forensic_entry_is_valid_json: all fields valid" "valid" "$_TEST6_VALID"

rm -rf "$_TEST6_DIR"

# ============================================================
# test_post_bash_144_missing_start_timestamp
# When exit_code=144 but no start timestamp file exists,
# the entry should have elapsed_s=-1 and cause="unknown".
# ============================================================
_TEST7_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST7_DIR")
# Do NOT create a bash-start-ts file — simulate missing pre-hook timestamp

_TEST7_INPUT='{"tool_name":"Bash","tool_input":{"command":"some long command"},"tool_response":{"exit_code":144}}'

echo "$_TEST7_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST7_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST7_JSONL="$_TEST7_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST7_JSONL" ]]; then
    _TEST7_ELAPSED=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('elapsed_s',''))" < "$_TEST7_JSONL")
    _TEST7_CAUSE=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('cause',''))" < "$_TEST7_JSONL")
else
    _TEST7_ELAPSED=""
    _TEST7_CAUSE=""
fi
assert_eq "test_post_bash_144_missing_start_timestamp: elapsed_s is -1" "-1.0" "$_TEST7_ELAPSED"
assert_eq "test_post_bash_144_missing_start_timestamp: cause is unknown" "unknown" "$_TEST7_CAUSE"

rm -rf "$_TEST7_DIR"

# ============================================================
# test_post_bash_classification_at_boundary
# Tests the 70000ms threshold: < 70000ms → cancellation, >= 70000ms → timeout.
# Uses values with margin to avoid wall-clock drift between test setup
# and function execution (function computes its own NOW_MS).
# ============================================================
# Boundary test A: 65000ms → cancellation (clearly < 70000ms even with drift)
_TEST8A_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST8A_DIR")
_TEST8A_COMMAND="boundary test A"
_TEST8A_HASH=$(echo -n "$_TEST8A_COMMAND" | hash_stdin | cut -c1-8)

_TEST8A_NOW_MS=$(python3 -c 'import time;print(int(time.time()*1e3))')
_TEST8A_START_MS=$(( _TEST8A_NOW_MS - 65000 ))
echo "$_TEST8A_START_MS" > "$_TEST8A_DIR/bash-start-ts-${_TEST8A_HASH}"

_TEST8A_INPUT='{"tool_name":"Bash","tool_input":{"command":"boundary test A"},"tool_response":{"exit_code":144}}'

echo "$_TEST8A_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST8A_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST8A_JSONL="$_TEST8A_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST8A_JSONL" ]]; then
    _TEST8A_CAUSE=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('cause',''))" < "$_TEST8A_JSONL")
else
    _TEST8A_CAUSE=""
fi
assert_eq "test_post_bash_classification_at_boundary: 65000ms=cancellation" "cancellation" "$_TEST8A_CAUSE"

rm -rf "$_TEST8A_DIR"

# Boundary test B: 75000ms → timeout (clearly >= 70000ms)
_TEST8B_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST8B_DIR")
_TEST8B_COMMAND="boundary test B"
_TEST8B_HASH=$(echo -n "$_TEST8B_COMMAND" | hash_stdin | cut -c1-8)

_TEST8B_NOW_MS=$(python3 -c 'import time;print(int(time.time()*1e3))')
_TEST8B_START_MS=$(( _TEST8B_NOW_MS - 75000 ))
echo "$_TEST8B_START_MS" > "$_TEST8B_DIR/bash-start-ts-${_TEST8B_HASH}"

_TEST8B_INPUT='{"tool_name":"Bash","tool_input":{"command":"boundary test B"},"tool_response":{"exit_code":144}}'

echo "$_TEST8B_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST8B_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST8B_JSONL="$_TEST8B_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST8B_JSONL" ]]; then
    _TEST8B_CAUSE=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('cause',''))" < "$_TEST8B_JSONL")
else
    _TEST8B_CAUSE=""
fi
assert_eq "test_post_bash_classification_at_boundary: 75000ms=timeout" "timeout" "$_TEST8B_CAUSE"

rm -rf "$_TEST8B_DIR"

# ============================================================
# test_post_bash_missing_exit_code_field
# When the JSON input has no exit_code field at all, the hook
# should return cleanly without creating a JSONL file.
# ============================================================
_TEST9_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST9_DIR")
_TEST9_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"output":"hi"}}'

echo "$_TEST9_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST9_DIR" bash "$POST_HOOK" 2>/dev/null || true

_TEST9_JSONL="$_TEST9_DIR/exit-144-forensics.jsonl"
if [[ -f "$_TEST9_JSONL" ]]; then
    _TEST9_NO_FILE="no"
else
    _TEST9_NO_FILE="yes"
fi
assert_eq "test_post_bash_missing_exit_code_field: no jsonl file" "yes" "$_TEST9_NO_FILE"

rm -rf "$_TEST9_DIR"

# ============================================================
# Part 3: Companion analysis script tests
# ============================================================
ANALYZE_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/analyze-exit-144.sh"

# ============================================================
# test_analyze_script_handles_missing_file
# When the log file does not exist, the script should print
# "No exit-144 events recorded." and exit 0.
# ============================================================
_TEST10_OUTPUT=$(bash "$ANALYZE_SCRIPT" --file /tmp/nonexistent-file-$$.jsonl 2>/dev/null)
_TEST10_EXIT=$?
assert_eq "test_analyze_script_handles_missing_file: exit 0" "0" "$_TEST10_EXIT"
assert_contains "test_analyze_script_handles_missing_file: message" "No exit-144 events recorded." "$_TEST10_OUTPUT"

# ============================================================
# test_analyze_script_handles_empty_jsonl
# When the log file exists but is empty, the script should print
# "No exit-144 events recorded." and exit 0.
# ============================================================
_TEST11_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST11_DIR")
_TEST11_FILE="$_TEST11_DIR/exit-144-forensics.jsonl"
touch "$_TEST11_FILE"

_TEST11_OUTPUT=$(bash "$ANALYZE_SCRIPT" --file "$_TEST11_FILE" 2>/dev/null)
_TEST11_EXIT=$?
assert_eq "test_analyze_script_handles_empty_jsonl: exit 0" "0" "$_TEST11_EXIT"
assert_contains "test_analyze_script_handles_empty_jsonl: message" "No exit-144 events recorded." "$_TEST11_OUTPUT"

rm -rf "$_TEST11_DIR"

# ============================================================
# test_analyze_script_reports_patterns
# Given synthetic JSONL with known data, the script should produce
# three report sections: top commands, cause breakdown, elapsed stats.
# ============================================================
_TEST12_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST12_DIR")
_TEST12_FILE="$_TEST12_DIR/exit-144-forensics.jsonl"

# Write synthetic JSONL entries
cat > "$_TEST12_FILE" <<'JSONL'
{"timestamp":"2026-03-14T10:00:00Z","command":"make test-unit-only","elapsed_s":80.5,"cause":"timeout","cwd":"/app"}
{"timestamp":"2026-03-14T10:01:00Z","command":"make test-unit-only","elapsed_s":75.0,"cause":"timeout","cwd":"/app"}
{"timestamp":"2026-03-14T10:02:00Z","command":"make test-unit-only","elapsed_s":90.2,"cause":"timeout","cwd":"/app"}
{"timestamp":"2026-03-14T10:03:00Z","command":"poetry run pytest","elapsed_s":45.0,"cause":"cancellation","cwd":"/app"}
{"timestamp":"2026-03-14T10:04:00Z","command":"poetry run pytest","elapsed_s":50.0,"cause":"cancellation","cwd":"/app"}
{"timestamp":"2026-03-14T10:05:00Z","command":"git status","elapsed_s":30.0,"cause":"cancellation","cwd":"/app"}
JSONL

_TEST12_OUTPUT=$(bash "$ANALYZE_SCRIPT" --file "$_TEST12_FILE" 2>/dev/null)
_TEST12_EXIT=$?
assert_eq "test_analyze_script_reports_patterns: exit 0" "0" "$_TEST12_EXIT"

# Should contain top commands section with "make test-unit-only" as #1 (3 occurrences)
assert_contains "test_analyze_script_reports_patterns: top commands header" "Top" "$_TEST12_OUTPUT"
assert_contains "test_analyze_script_reports_patterns: top command entry" "make test-unit-only" "$_TEST12_OUTPUT"

# Should contain cause breakdown with timeout and cancellation percentages
assert_contains "test_analyze_script_reports_patterns: cause header" "Cause" "$_TEST12_OUTPUT"
assert_contains "test_analyze_script_reports_patterns: timeout count" "timeout" "$_TEST12_OUTPUT"
assert_contains "test_analyze_script_reports_patterns: cancellation count" "cancellation" "$_TEST12_OUTPUT"

# Should contain elapsed time stats (min=30.0, max=90.2, median, p90)
assert_contains "test_analyze_script_reports_patterns: elapsed header" "Elapsed" "$_TEST12_OUTPUT"
assert_contains "test_analyze_script_reports_patterns: min value" "30.0" "$_TEST12_OUTPUT"
assert_contains "test_analyze_script_reports_patterns: max value" "90.2" "$_TEST12_OUTPUT"

rm -rf "$_TEST12_DIR"

# ============================================================
# test_analyze_script_handles_malformed_lines
# Malformed JSONL lines should be skipped with a count message.
# ============================================================
_TEST13_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST13_DIR")
_TEST13_FILE="$_TEST13_DIR/exit-144-forensics.jsonl"

cat > "$_TEST13_FILE" <<'JSONL'
{"timestamp":"2026-03-14T10:00:00Z","command":"make test","elapsed_s":80.0,"cause":"timeout","cwd":"/app"}
this is not json
{"timestamp":"2026-03-14T10:01:00Z","command":"make test","elapsed_s":70.0,"cause":"timeout","cwd":"/app"}
also bad {{{
JSONL

_TEST13_OUTPUT=$(bash "$ANALYZE_SCRIPT" --file "$_TEST13_FILE" 2>/dev/null)
_TEST13_EXIT=$?
assert_eq "test_analyze_script_handles_malformed_lines: exit 0" "0" "$_TEST13_EXIT"
assert_contains "test_analyze_script_handles_malformed_lines: skip message" "Skipped 2 malformed" "$_TEST13_OUTPUT"
# Should still report on the 2 valid entries
assert_contains "test_analyze_script_handles_malformed_lines: valid data reported" "make test" "$_TEST13_OUTPUT"

rm -rf "$_TEST13_DIR"

# ============================================================
# Part 4: PostToolUseFailure path tests
# The forensic logger must also work when invoked from
# PostToolUseFailure, which provides a different input schema:
#   .error = "Command exited with non-zero status code 144"
#   (no .tool_response.exit_code field)
# ============================================================

# Isolate HOME for all Part 4 tests so synthetic errors don't pollute
# ~/.claude/tool-error-counter.json (post-failure dispatcher calls track-tool-errors.sh)
_PART4_REAL_HOME="$HOME"
_PART4_TEST_HOME=$(mktemp -d)
_CLEANUP_DIRS+=("$_PART4_TEST_HOME")
export HOME="$_PART4_TEST_HOME"

POST_FAILURE_HOOK="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-failure.sh"

# ============================================================
# test_post_failure_144_writes_jsonl
# PostToolUseFailure input with "status code 144" in .error
# should trigger forensic logging.
# ============================================================
_TEST14_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST14_DIR")
_TEST14_COMMAND="make test-unit-only"
_TEST14_HASH=$(echo -n "$_TEST14_COMMAND" | hash_stdin | cut -c1-8)

# Write a start timestamp 80s ago (should classify as timeout)
_TEST14_NOW_MS=$(python3 -c 'import time;print(int(time.time()*1e3))')
_TEST14_START_MS=$(( _TEST14_NOW_MS - 80000 ))
echo "$_TEST14_START_MS" > "$_TEST14_DIR/bash-start-ts-${_TEST14_HASH}"

_TEST14_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only"},"tool_use_id":"toolu_test","error":"Command exited with non-zero status code 144","is_interrupt":false}'

echo "$_TEST14_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST14_DIR" bash "$POST_FAILURE_HOOK" 2>/dev/null || true

_TEST14_JSONL="$_TEST14_DIR/exit-144-forensics.jsonl"
_snapshot_fail
if [[ -f "$_TEST14_JSONL" ]]; then
    _TEST14_CMD=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('command',''))" < "$_TEST14_JSONL")
    _TEST14_CAUSE=$(python3 -c "import json,sys; d=json.loads(sys.stdin.readline()); print(d.get('cause',''))" < "$_TEST14_JSONL")
else
    _TEST14_CMD=""
    _TEST14_CAUSE=""
fi
assert_eq "test_post_failure_144_writes_jsonl: command captured" "make test-unit-only" "$_TEST14_CMD"
assert_eq "test_post_failure_144_writes_jsonl: cause=timeout (80s)" "timeout" "$_TEST14_CAUSE"
assert_pass_if_clean "test_post_failure_144_writes_jsonl"

rm -rf "$_TEST14_DIR"

# ============================================================
# test_post_failure_non_144_no_jsonl
# PostToolUseFailure with a non-144 error should NOT create
# a forensics file.
# ============================================================
_TEST15_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST15_DIR")
_TEST15_INPUT='{"tool_name":"Bash","tool_input":{"command":"false"},"tool_use_id":"toolu_test","error":"Command exited with non-zero status code 1","is_interrupt":false}'

echo "$_TEST15_INPUT" | WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_TEST15_DIR" bash "$POST_FAILURE_HOOK" 2>/dev/null || true

_TEST15_JSONL="$_TEST15_DIR/exit-144-forensics.jsonl"
_snapshot_fail
if [[ -f "$_TEST15_JSONL" ]]; then
    _TEST15_NO_FILE="no"
else
    _TEST15_NO_FILE="yes"
fi
assert_eq "test_post_failure_non_144_no_jsonl: no file" "yes" "$_TEST15_NO_FILE"
assert_pass_if_clean "test_post_failure_non_144_no_jsonl"

rm -rf "$_TEST15_DIR"

# Restore real HOME after Part 4 tests
export HOME="$_PART4_REAL_HOME"

print_summary
