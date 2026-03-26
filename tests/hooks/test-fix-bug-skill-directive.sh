#!/usr/bin/env bash
# tests/hooks/test-fix-bug-skill-directive.sh
# Behavioral tests for the UserPromptSubmit fix-bug-skill-directive hook.
#
# The hook (plugins/dso/hooks/fix-bug-skill-directive.sh) reads a JSON
# payload from stdin and outputs a skill directive to stdout when the user's
# prompt contains a /fix-bug (or /dso:fix-bug) invocation. It must exit 0
# in all cases (hooks must never fail).
#
# Research note: Claude Code UserPromptSubmit hook payload (confirmed from
# official docs at https://code.claude.com/docs/en/hooks) uses the field
# name "prompt" for the user's submitted text:
#   {
#     "session_id": "...",
#     "transcript_path": "...",
#     "cwd": "...",
#     "permission_mode": "default",
#     "hook_event_name": "UserPromptSubmit",
#     "prompt": "<user text here>"
#   }
# Delivery mechanism: JSON on stdin (consistent with all other hooks in this repo).
#
# HOOK_FIELD_NAME env var allows overriding the JSON field name for tests if
# the actual field name differs from the confirmed value ("prompt").
# Default: "prompt" (confirmed from official Claude Code documentation).
#
# RED PHASE: Tests fail until plugins/dso/hooks/fix-bug-skill-directive.sh
# is implemented (Task 2).
#
# Usage:
#   bash tests/hooks/test-fix-bug-skill-directive.sh

set -uo pipefail
# Note: set -e omitted intentionally — tests call hook scripts that return
# non-zero and we handle all assertions via assert_eq/assert_contains.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

HOOK_SCRIPT="$DSO_PLUGIN_DIR/hooks/fix-bug-skill-directive.sh"

# Configurable field name — default to confirmed value from official docs.
# Override via HOOK_FIELD_NAME env var if field name differs from "prompt".
FIELD_NAME="${HOOK_FIELD_NAME:-prompt}"

# _make_payload <message>
# Builds a minimal UserPromptSubmit JSON payload with the user message in
# the configured field (default: "prompt").
_make_payload() {
    local msg="$1"
    # Escape double quotes and backslashes in the message for JSON embedding
    local escaped
    escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"hook_event_name":"UserPromptSubmit","session_id":"test-session","cwd":"/tmp","permission_mode":"default","%s":"%s"}' \
        "$FIELD_NAME" "$escaped"
}

echo "=== test-fix-bug-skill-directive.sh ==="

# ============================================================
# test_fix_bug_slash_command_triggers_directive
# Piping a message containing '/fix-bug' should produce output
# on stdout containing 'Skill' (or similar directive text).
# Exit code must be 0.
# ============================================================
test_fix_bug_slash_command_triggers_directive() {
    local _exit_code=0
    local _output=""
    local _payload
    _payload=$(_make_payload "/fix-bug the login regression")
    _output=$(printf '%s' "$_payload" | bash "$HOOK_SCRIPT" 2>/dev/null) || _exit_code=$?
    assert_eq "test_fix_bug_slash_command_triggers_directive: exit 0" "0" "$_exit_code"
    assert_contains "test_fix_bug_slash_command_triggers_directive: stdout contains directive" "Skill" "$_output"
}

# ============================================================
# test_fix_bug_qualified_command_triggers_directive
# Piping a message containing '/dso:fix-bug' should produce the
# same directive output. Exit code must be 0.
# ============================================================
test_fix_bug_qualified_command_triggers_directive() {
    local _exit_code=0
    local _output=""
    local _payload
    _payload=$(_make_payload "/dso:fix-bug the null pointer error")
    _output=$(printf '%s' "$_payload" | bash "$HOOK_SCRIPT" 2>/dev/null) || _exit_code=$?
    assert_eq "test_fix_bug_qualified_command_triggers_directive: exit 0" "0" "$_exit_code"
    assert_contains "test_fix_bug_qualified_command_triggers_directive: stdout contains directive" "Skill" "$_output"
}

# ============================================================
# test_fix_bug_unrelated_message_produces_no_output
# A message that does NOT contain /fix-bug (e.g., 'fix the login bug')
# should produce empty stdout. Exit code must be 0.
# ============================================================
test_fix_bug_unrelated_message_produces_no_output() {
    local _exit_code=0
    local _output=""
    local _payload
    _payload=$(_make_payload "fix the login bug in the auth module")
    _output=$(printf '%s' "$_payload" | bash "$HOOK_SCRIPT" 2>/dev/null) || _exit_code=$?
    assert_eq "test_fix_bug_unrelated_message_produces_no_output: exit 0" "0" "$_exit_code"
    assert_eq "test_fix_bug_unrelated_message_produces_no_output: stdout is empty" "" "$_output"
}

# ============================================================
# test_fix_bug_embedded_in_sentence_triggers_directive
# '/fix-bug' embedded in a longer sentence should still fire the
# directive. Exit code must be 0.
# ============================================================
test_fix_bug_embedded_in_sentence_triggers_directive() {
    local _exit_code=0
    local _output=""
    local _payload
    _payload=$(_make_payload "please use /fix-bug to investigate the crash in production")
    _output=$(printf '%s' "$_payload" | bash "$HOOK_SCRIPT" 2>/dev/null) || _exit_code=$?
    assert_eq "test_fix_bug_embedded_in_sentence_triggers_directive: exit 0" "0" "$_exit_code"
    assert_contains "test_fix_bug_embedded_in_sentence_triggers_directive: stdout contains directive" "Skill" "$_output"
}

# ============================================================
# test_fix_bug_pattern_match
# (RED marker boundary — tests above GREEN once implemented,
# tests at/after this marker are the RED boundary)
#
# Additional slash-command variant: '/fix-bug' at start of message
# with no surrounding context. Exit code 0, stdout contains directive.
# ============================================================
test_fix_bug_pattern_match() {
    local _exit_code=0
    local _output=""
    local _payload
    _payload=$(_make_payload "/fix-bug")
    _output=$(printf '%s' "$_payload" | bash "$HOOK_SCRIPT" 2>/dev/null) || _exit_code=$?
    assert_eq "test_fix_bug_pattern_match: exit 0 for bare /fix-bug" "0" "$_exit_code"
    assert_contains "test_fix_bug_pattern_match: stdout contains directive for bare /fix-bug" "Skill" "$_output"
}

# ============================================================
# test_fix_bug_bare_substring_no_false_positive
# 'fix-bug' WITHOUT a leading slash (e.g., 'the fix-bug process')
# must NOT trigger the directive (slash-anchored matching only).
# stdout must be empty, exit code 0.
# ============================================================
test_fix_bug_bare_substring_no_false_positive() {
    local _exit_code=0
    local _output=""
    local _payload
    _payload=$(_make_payload "the fix-bug process is documented in the wiki")
    _output=$(printf '%s' "$_payload" | bash "$HOOK_SCRIPT" 2>/dev/null) || _exit_code=$?
    assert_eq "test_fix_bug_bare_substring_no_false_positive: exit 0" "0" "$_exit_code"
    assert_eq "test_fix_bug_bare_substring_no_false_positive: stdout is empty (no false positive)" "" "$_output"
}

# --- Run all tests ---
echo "--- test_fix_bug_slash_command_triggers_directive ---"
test_fix_bug_slash_command_triggers_directive

echo "--- test_fix_bug_qualified_command_triggers_directive ---"
test_fix_bug_qualified_command_triggers_directive

echo "--- test_fix_bug_unrelated_message_produces_no_output ---"
test_fix_bug_unrelated_message_produces_no_output

echo "--- test_fix_bug_embedded_in_sentence_triggers_directive ---"
test_fix_bug_embedded_in_sentence_triggers_directive

echo "--- test_fix_bug_pattern_match ---"
test_fix_bug_pattern_match

echo "--- test_fix_bug_bare_substring_no_false_positive ---"
test_fix_bug_bare_substring_no_false_positive

print_summary
