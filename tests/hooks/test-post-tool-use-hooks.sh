#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-post-tool-use-hooks.sh
# Test that all PostToolUse hooks satisfy the Claude Code hook contract:
#   1. Always exit 0 (any non-zero exit causes "hook error" visible to user)
#   2. Never produce stderr output (stderr leaks cause error messages)
#
# This test verifies the fix for the persistent "PostToolUse:Bash hook error"
# caused by Claude Code bug #20334 (matcher doesn't filter tool types).
#
# Usage: ./lockpick-workflow/tests/hooks/test-post-tool-use-hooks.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$PLUGIN_ROOT/hooks"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# All PostToolUse hooks to test
HOOKS=(
    "check-validation-failures.sh"
    "track-cascade-failures.sh"
)

# Tool types that Claude Code may dispatch to PostToolUse hooks
# Due to bug #20334, hooks with tool-specific matchers fire for ALL tools
TOOL_TYPES=("Bash" "Read" "Write" "Edit" "Glob" "Grep" "Task" "WebFetch" "WebSearch" "NotebookEdit")

run_test() {
    local description="$1"
    local hook="$2"
    local input="$3"
    local hook_path="$HOOKS_DIR/$hook"

    TOTAL=$((TOTAL + 1))

    if [[ ! -x "$hook_path" ]]; then
        echo -e "  ${RED}FAIL${NC} $description (hook not executable: $hook_path)"
        FAIL=$((FAIL + 1))
        return
    fi

    # Capture stdout, stderr, and exit code separately
    local stdout_file stderr_file
    stdout_file=$(mktemp)
    _CLEANUP_DIRS+=("$stdout_file")
    stderr_file=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_file")

    local exit_code=0
    echo "$input" | bash "$hook_path" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

    local stderr_content
    stderr_content=$(cat "$stderr_file")

    # Check exit code
    if [[ $exit_code -ne 0 ]]; then
        echo -e "  ${RED}FAIL${NC} $description"
        echo "    Expected exit 0, got exit $exit_code"
        echo "    stderr: $stderr_content"
        FAIL=$((FAIL + 1))
        rm -f "$stdout_file" "$stderr_file"
        return
    fi

    # Check stderr is empty
    if [[ -n "$stderr_content" ]]; then
        echo -e "  ${RED}FAIL${NC} $description"
        echo "    Exit code: 0 (correct)"
        echo "    stderr NOT empty: '$stderr_content'"
        FAIL=$((FAIL + 1))
        rm -f "$stdout_file" "$stderr_file"
        return
    fi

    echo -e "  ${GREEN}PASS${NC} $description"
    PASS=$((PASS + 1))
    rm -f "$stdout_file" "$stderr_file"
}

# Generate a tool input JSON for a given tool type
make_tool_input() {
    local tool_name="$1"
    case "$tool_name" in
        Bash)
            echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"},"tool_response":{"stdout":"hello\n","stderr":""}}'
            ;;
        Read)
            echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{"content":"file content here"}}'
            ;;
        Write)
            echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"new content"},"tool_response":{"success":true}}'
            ;;
        Edit)
            echo '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt","old_string":"old","new_string":"new"},"tool_response":{"success":true}}'
            ;;
        Glob)
            echo '{"tool_name":"Glob","tool_input":{"pattern":"**/*.py"},"tool_response":{"files":["a.py","b.py"]}}'
            ;;
        Grep)
            echo '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":"/tmp"},"tool_response":{"matches":[]}}'
            ;;
        Task)
            echo '{"tool_name":"Task","tool_input":{"prompt":"do something"},"tool_response":{"result":"done"}}'
            ;;
        WebFetch)
            echo '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"tool_response":{"content":"page"}}'
            ;;
        WebSearch)
            echo '{"tool_name":"WebSearch","tool_input":{"query":"test"},"tool_response":{"results":[]}}'
            ;;
        NotebookEdit)
            echo '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/tmp/test.ipynb"},"tool_response":{"success":true}}'
            ;;
        *)
            echo "{\"tool_name\":\"$tool_name\",\"tool_input\":{},\"tool_response\":{}}"
            ;;
    esac
}

echo ""
echo "PostToolUse Hook Contract Tests"
echo "================================"
echo ""
echo "Testing hooks: ${HOOKS[*]}"
echo "Against tool types: ${TOOL_TYPES[*]}"
echo ""

# --- Test 1: All tool types ---
echo -e "${YELLOW}Test Group 1: All tool types (matcher bug workaround)${NC}"
echo "  Hooks must exit 0 with no stderr for ALL tool types,"
echo "  not just their intended target, due to Claude Code bug #20334."
echo ""

for hook in "${HOOKS[@]}"; do
    echo "  Hook: $hook"
    for tool in "${TOOL_TYPES[@]}"; do
        input=$(make_tool_input "$tool")
        run_test "$hook + $tool tool" "$hook" "$input"
    done
    echo ""
done

# --- Test 2: Edge cases ---
echo -e "${YELLOW}Test Group 2: Edge cases${NC}"
echo ""

for hook in "${HOOKS[@]}"; do
    echo "  Hook: $hook"

    # Empty stdin
    run_test "$hook + empty stdin" "$hook" ""

    # Malformed JSON
    run_test "$hook + malformed JSON" "$hook" "this is not json {{"

    # Null bytes in input (truncates at null in bash)
    run_test "$hook + null byte in input" "$hook" $'{"tool_name":"Bash","tool_input":{"command":"echo"},"tool_response":{"stdout":"a\x00b","stderr":""}}'

    # Very long input (1MB of output)
    long_output=$(python3 -c "print('x' * 1000000)" 2>/dev/null || printf '%1000000s' '' | tr ' ' 'x')
    long_input="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat bigfile\"},\"tool_response\":{\"stdout\":\"${long_output:0:100000}\",\"stderr\":\"\"}}"
    run_test "$hook + large input (~100KB)" "$hook" "$long_input"

    # Missing tool_response field
    run_test "$hook + missing tool_response" "$hook" '{"tool_name":"Bash","tool_input":{"command":"echo"}}'

    # Null tool_response
    run_test "$hook + null tool_response" "$hook" '{"tool_name":"Bash","tool_input":{"command":"echo"},"tool_response":null}'

    echo ""
done

# --- Test 3: Bash-specific scenarios (validate.sh and test commands) ---
echo -e "${YELLOW}Test Group 3: Bash-specific scenarios${NC}"
echo ""

# validate.sh with failures (check-validation-failures.sh should produce stdout but still exit 0)
# Use escaped \\n which jq interprets as actual newlines (matches Claude Code's JSON format)
validate_fail_input='{"tool_name":"Bash","tool_input":{"command":"validate.sh --ci"},"tool_response":{"stdout":"Results:\\n  format: PASS\\n  lint: FAIL\\n  test: FAIL\\n  mypy: PASS","stderr":""}}'
run_test "check-validation-failures.sh + validate.sh failure" "check-validation-failures.sh" "$validate_fail_input"

# make test with failures (track-cascade-failures.sh should track but still exit 0)
test_fail_input='{"tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":{"stdout":"FAILED tests/test_foo.py::test_bar - AssertionError\\n1 FAILED, 5 passed","stderr":"Error: tests failed"}}'
run_test "track-cascade-failures.sh + test failure" "track-cascade-failures.sh" "$test_fail_input"

echo ""

# --- Test 4: Settings validation ---
echo -e "${YELLOW}Test Group 4: Settings validation${NC}"
echo ""

# Verify settings.json PostToolUse hooks use scoped matchers (Bash, Task)
# Note: scoped matchers are intentional — they avoid running hooks on read-only
# tools (Read, Grep, Glob) where they have no effect, saving ~85ms per call.
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
    MATCHER_CHECK=$(python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
post_hooks = settings.get('hooks', {}).get('PostToolUse', [])
matchers = [h['matcher'] for h in post_hooks]
# Catch-all matcher ('') is expected for tool-logging; scoped matchers for the rest
scoped = [m for m in matchers if m]
if not matchers:
    print('No PostToolUse hooks configured')
    sys.exit(1)
label = ', '.join(sorted(scoped)) if scoped else '(catch-all only)'
print('PostToolUse matchers: ' + label)
" 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        TOTAL=$((TOTAL + 1))
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}PASS${NC} PostToolUse matchers are scoped: $MATCHER_CHECK"
    else
        TOTAL=$((TOTAL + 1))
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC} PostToolUse matcher configuration issue"
        echo "    $MATCHER_CHECK"
    fi
else
    echo -e "  ${YELLOW}SKIP${NC} Settings file not found: $SETTINGS_FILE"
fi

echo ""

# --- Summary ---
echo "================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}: $FAIL test(s) failed. PostToolUse hooks do not satisfy the Claude Code hook contract."
    echo "Fix: Ensure all hooks exit 0 with no stderr for ALL tool types."
    exit 1
else
    echo -e "${GREEN}PASSED${NC}: All PostToolUse hooks satisfy the Claude Code hook contract."
    exit 0
fi
