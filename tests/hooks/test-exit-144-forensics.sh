#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-exit-144-forensics.sh
# Tests for exit-144 forensic logger: PreToolUse dispatcher records Bash start timestamps.
#
# Validates:
#   - Bash tool calls create a command-hash-keyed timestamp file (bash-start-ts-XXXXXXXX)
#   - Non-Bash tool calls do NOT create timestamp files
#   - Timestamp value is a numeric millisecond timestamp

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-bash.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# ============================================================
# test_pre_bash_records_start_timestamp
# A Bash tool call should create a bash-start-ts-<hash> file
# in the artifacts directory with a numeric timestamp value.
# ============================================================
_TEST1_DIR=$(mktemp -d)
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

print_summary
