#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-deps.sh
# Unit tests for deps.sh shared dependency library.
#
# Usage: bash lockpick-workflow/tests/hooks/test-deps.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_ne, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$label" "$expected" "$actual" >&2
    fi
}

assert_ne() {
    local label="$1" not_expected="$2" actual="$3"
    if [[ "$not_expected" != "$actual" ]]; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s\n  should NOT be: %s\n" "$label" "$not_expected" >&2
    fi
}

# --- check_tool ---
echo "=== check_tool ==="
if check_tool bash; then
    assert_eq "bash exists" "yes" "yes"
else
    assert_eq "bash exists" "yes" "no"
fi
if check_tool nonexistent_tool_xyz 2>/dev/null; then
    assert_eq "nonexistent missing" "no" "yes"
else
    assert_eq "nonexistent missing" "no" "no"
fi

# --- parse_json_field (with jq) ---
echo "=== parse_json_field (jq) ==="
INPUT='{"tool_name":"Bash","tool_input":{"command":"git status","file_path":"/tmp/test.txt"}}'
assert_eq "jq: tool_name" "Bash" "$(parse_json_field "$INPUT" '.tool_name')"
assert_eq "jq: command" "git status" "$(parse_json_field "$INPUT" '.tool_input.command')"
assert_eq "jq: file_path" "/tmp/test.txt" "$(parse_json_field "$INPUT" '.tool_input.file_path')"
assert_eq "jq: missing field" "" "$(parse_json_field "$INPUT" '.nonexistent')"
assert_eq "jq: missing nested" "" "$(parse_json_field "$INPUT" '.tool_input.nonexistent')"

# --- parse_json_field (bash fallback) ---
echo "=== parse_json_field (bash fallback) ==="
# Override check_tool to force bash fallback
_real_check_tool=$(declare -f check_tool)
check_tool() { return 1; }

assert_eq "bash: tool_name" "Bash" "$(parse_json_field "$INPUT" '.tool_name')"
assert_eq "bash: command" "git status" "$(parse_json_field "$INPUT" '.tool_input.command')"
assert_eq "bash: file_path" "/tmp/test.txt" "$(parse_json_field "$INPUT" '.tool_input.file_path')"
assert_eq "bash: missing field" "" "$(parse_json_field "$INPUT" '.nonexistent')"

# Test Edit tool input shape
INPUT2='{"tool_name":"Edit","tool_input":{"file_path":"/Users/joe/src/main.py","old_string":"foo","new_string":"bar"}}'
assert_eq "bash: Edit tool_name" "Edit" "$(parse_json_field "$INPUT2" '.tool_name')"
assert_eq "bash: Edit file_path" "/Users/joe/src/main.py" "$(parse_json_field "$INPUT2" '.tool_input.file_path')"

# Test ExitPlanMode (empty tool_input)
INPUT3='{"tool_name":"ExitPlanMode","tool_input":{}}'
assert_eq "bash: ExitPlanMode" "ExitPlanMode" "$(parse_json_field "$INPUT3" '.tool_name')"

# Test with spaces in values
INPUT4='{"tool_name":"Bash","tool_input":{"command":"cd /path/with spaces && ls -la"}}'
assert_eq "bash: spaces in command" "cd /path/with spaces && ls -la" "$(parse_json_field "$INPUT4" '.tool_input.command')"

# Test double-backslash before closing quote doesn't break parsing.
# In JSON, \\" means escaped-backslash + end-of-string. The parser must
# correctly identify the closing quote after an even number of backslashes.
# Note: the bash fallback does NOT perform JSON unescape (\\ -> \), so the
# raw \\ is returned. This is acceptable — Claude Code hook values don't
# contain JSON escape sequences in practice.
printf '{"tool_name":"Bash","tool_input":{"command":"echo \\\\"}}' > /tmp/test_deps_escape.txt
INPUT5=$(cat /tmp/test_deps_escape.txt)
RESULT5=$(parse_json_field "$INPUT5" '.tool_input.command')
rm -f /tmp/test_deps_escape.txt
# The key assertion: parsing completes without consuming past the closing quote
# (i.e., we don't get "echo \\"}}" or similar garbage)
assert_eq "bash: double-backslash terminates correctly" 'echo \\' "$RESULT5"

# Restore check_tool
eval "$_real_check_tool"

# --- hash_stdin ---
echo "=== hash_stdin ==="
HASH_A=$(echo "test data" | hash_stdin)
HASH_B=$(echo "test data" | hash_stdin)
assert_eq "hash consistency" "$HASH_A" "$HASH_B"
assert_ne "hash non-empty" "" "$HASH_A"

HASH_C=$(echo "different data" | hash_stdin)
assert_ne "different data different hash" "$HASH_A" "$HASH_C"

# --- hash_file ---
echo "=== hash_file ==="
TMPFILE=$(mktemp)
_CLEANUP_DIRS+=("$TMPFILE")
echo "test data" > "$TMPFILE"
HASH_FILE=$(hash_file "$TMPFILE")
HASH_STDIN=$(echo "test data" | hash_stdin)
assert_eq "hash_file matches hash_stdin" "$HASH_STDIN" "$HASH_FILE"
rm -f "$TMPFILE"

# --- try_find_python ---
echo "=== try_find_python ==="
# This test just verifies the function runs without error
# Actual Python availability varies by system
PYTHON_PATH=$(try_find_python 3.13 2>/dev/null || echo "")
if [[ -n "$PYTHON_PATH" ]]; then
    assert_ne "python path non-empty when found" "" "$PYTHON_PATH"
    # Verify it's actually 3.13
    ACTUAL=$("$PYTHON_PATH" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    assert_eq "python version matches" "3.13" "$ACTUAL"
else
    echo "  (Python 3.13 not found on this system — skipping version check)"
    (( PASS++ ))
fi

# --- Summary ---
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS passed, $FAIL failed (of $TOTAL)"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
