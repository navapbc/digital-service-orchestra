#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-check-validation-failures.sh
# Tests for .claude/hooks/check-validation-failures.sh
#
# check-validation-failures.sh is a PostToolUse hook that auto-creates
# ticket tracking issues when validate.sh outputs FAIL lines.
# It always exits 0 (non-blocking).

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/check-validation-failures.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" > /dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    local input="$1"
    echo "$input" | bash "$HOOK" 2>/dev/null
}

# test_check_validation_exits_zero_on_passing_bash_response
# Bash tool with exit_code=0 and no validate.sh invocation → exit 0
INPUT='{"tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":{"exit_code":0}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_check_validation_exits_zero_on_passing_bash_response" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_non_bash_tool
# Non-Bash tool calls should be silently ignored
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"},"tool_response":{"content":""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_check_validation_exits_zero_on_non_bash_tool" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_non_validate_command
# Bash tool but not validate.sh → no-op, exit 0
INPUT='{"tool_name":"Bash","tool_input":{"command":"make format"},"tool_response":{"exit_code":0}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_check_validation_exits_zero_on_non_validate_command" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_empty_input
# Empty stdin → exit 0
EXIT_CODE=$(run_hook "")
assert_eq "test_check_validation_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_malformed_json
# Malformed JSON → exit 0 (fail-open)
EXIT_CODE=$(run_hook "not json {{")
assert_eq "test_check_validation_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_validate_with_no_failures
# validate.sh output with all PASS → exit 0, no output
INPUT='{"tool_name":"Bash","tool_input":{"command":"validate.sh --ci"},"tool_response":{"stdout":"  format:  PASS\n  lint:    PASS\n  tests:   PASS","exit_code":0}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_check_validation_exits_zero_on_validate_with_no_failures" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_validate_with_failures
# validate.sh with FAIL lines → exit 0 (hook is non-blocking even on failures)
# The hook tries to create ticket issues but still exits 0 regardless
INPUT='{"tool_name":"Bash","tool_input":{"command":"validate.sh --ci"},"tool_response":{"stdout":"  format:  FAIL\n  lint:    PASS\n  tests:   FAIL","exit_code":1}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_check_validation_exits_zero_on_validate_with_failures" "0" "$EXIT_CODE"

# test_check_validation_exits_zero_on_edit_tool
# Edit tool calls are ignored (hook only acts on Bash)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_check_validation_exits_zero_on_edit_tool" "0" "$EXIT_CODE"

# test_check_validation_failures_creates_tk_issue
# Stub tk in PATH and feed the hook a validate.sh FAIL output.
# Assert tk create was called with a bug title.
# MUST FAIL in red phase because the hook calls bd create, not tk create.
_CVF_FAKE_BIN=$(mktemp -d)
_CVF_TK_LOG="$_CVF_FAKE_BIN/tk.log"

# Create mock tk that records its arguments
cat > "$_CVF_FAKE_BIN/tk" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$TK_LOG"
echo "Created issue: tk-001"
MOCK_EOF
chmod +x "$_CVF_FAKE_BIN/tk"

_CVF_INPUT='{"tool_name":"Bash","tool_input":{"command":"validate.sh --ci"},"tool_response":{"stdout":"  format:  FAIL\n  lint:    PASS","exit_code":1}}'
# Create an empty TICKETS_DIR so no pre-existing tickets are found, forcing tk create to be called.
_CVF_EMPTY_TICKETS=$(mktemp -d)
# REVIEW-DEFENSE: TK_LOG, TICKETS_DIR, and PATH are prefixed to `bash "$HOOK"` (right side of pipe),
# not to `echo` (left side). Bash applies inline env assignments to the immediately
# following command, so the hook process inherits TK_LOG, the mock PATH, and the empty TICKETS_DIR.
echo "$_CVF_INPUT" | TK_LOG="$_CVF_TK_LOG" TICKETS_DIR="$_CVF_EMPTY_TICKETS" PATH="$_CVF_FAKE_BIN:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true
rm -rf "$_CVF_EMPTY_TICKETS"

# Check that tk create was called
_CVF_TK_CALLED="no"
if [[ -f "$_CVF_TK_LOG" ]] && grep -q "create" "$_CVF_TK_LOG" 2>/dev/null; then
    _CVF_TK_CALLED="yes"
fi
_CVF_FAIL_BEFORE2=$FAIL
assert_eq "test_check_validation_failures_creates_tk_issue" "yes" "$_CVF_TK_CALLED"
[[ $FAIL -eq $_CVF_FAIL_BEFORE2 ]] && echo "PASS: test_check_validation_failures_creates_tk_issue"

rm -rf "$_CVF_FAKE_BIN"

print_summary
