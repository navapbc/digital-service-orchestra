#!/usr/bin/env bash
# tests/hooks/test-jq-to-parse-json-field.sh
# Tests that track-cascade-failures.sh, check-validation-failures.sh,
# and pre-bash-functions.sh (hook_commit_failure_tracker) work correctly
# with parse_json_field instead of jq.
#
# Verifies: valid JSON, malformed JSON, missing fields, null values.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# --- Test isolation: unique fake git repo root per test run ---
# track-cascade-failures.sh computes STATE_DIR by hashing `git rev-parse --show-toplevel`.
# Using a unique fake root ensures counter files never collide with the real repo's
# cascade state or with parallel test runs.
_FAKE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-jq-parse-json-XXXXXX")
trap 'rm -rf "$_FAKE_ROOT"' EXIT
git init -q "$_FAKE_ROOT"
# Resolve to real path — on macOS, mktemp may return a symlink (e.g. /var/folders/...)
# but git rev-parse --show-toplevel resolves to the canonical path.
_FAKE_ROOT=$(cd "$_FAKE_ROOT" && git rev-parse --show-toplevel)

echo "=== test-jq-to-parse-json-field ==="

# -----------------------------------------------------------------------
# Test 1: parse_json_field handles .tool_response.stdout
# -----------------------------------------------------------------------
echo ""
echo "--- parse_json_field .tool_response.* support ---"

result=$(parse_json_field '{"tool_response":{"stdout":"hello world"}}' '.tool_response.stdout')
assert_eq "parse_json_field .tool_response.stdout" "hello world" "$result"

result=$(parse_json_field '{"tool_response":{"stderr":"error msg"}}' '.tool_response.stderr')
assert_eq "parse_json_field .tool_response.stderr" "error msg" "$result"

result=$(parse_json_field '{"tool_response":{"stdout":"out","stderr":"err"}}' '.tool_response.stdout')
assert_eq "parse_json_field .tool_response.stdout with both" "out" "$result"

result=$(parse_json_field '{"tool_response":{"stdout":"out","stderr":"err"}}' '.tool_response.stderr')
assert_eq "parse_json_field .tool_response.stderr with both" "err" "$result"

# Missing field
result=$(parse_json_field '{"tool_response":{}}' '.tool_response.stdout')
assert_eq "parse_json_field .tool_response.stdout missing" "" "$result"

# Missing parent
result=$(parse_json_field '{"tool_name":"Bash"}' '.tool_response.stdout')
assert_eq "parse_json_field .tool_response.stdout no parent" "" "$result"

# Null value — with jq available, returns "" (via // empty).
# Without jq (bash fallback), returns "null" as a literal non-string value.
# Both are acceptable for hook usage (the value is not used as a string match target).
result=$(parse_json_field '{"tool_response":{"stdout":null}}' '.tool_response.stdout')
# Accept either empty or "null" — both are correct depending on jq availability
if [[ "$result" == "" || "$result" == "null" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: parse_json_field .tool_response.stdout null\n  expected: '' or 'null'\n  actual:   %s\n" "$result" >&2
fi

# -----------------------------------------------------------------------
# Test 2: track-cascade-failures.sh field extraction
# -----------------------------------------------------------------------
echo ""
echo "--- track-cascade-failures.sh field extraction ---"

TRACK_HOOK="$DSO_PLUGIN_DIR/hooks/track-cascade-failures.sh"

# Non-Bash tool should exit silently (produces {} from trap)
output=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$TRACK_HOOK" 2>/dev/null)
assert_eq "track-cascade: non-Bash exits silently" "{}" "$output"

# Bash tool with non-test command should exit silently
output=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | bash "$TRACK_HOOK" 2>/dev/null)
assert_eq "track-cascade: non-test command exits silently" "{}" "$output"

# Bash tool with test command but passing output — resets state
# Compute state dir hash from _FAKE_ROOT (matches what the hook will compute
# when run from within _FAKE_ROOT via cd).
STATE_DIR_HASH=""
if command -v md5 &>/dev/null; then
    STATE_DIR_HASH=$(echo -n "$_FAKE_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    STATE_DIR_HASH=$(echo -n "$_FAKE_ROOT" | md5sum | cut -d' ' -f1)
else
    STATE_DIR_HASH=$(echo -n "$_FAKE_ROOT" | tr '/' '_')
fi
TEST_STATE_DIR="/tmp/claude-cascade-${STATE_DIR_HASH}"
mkdir -p "$TEST_STATE_DIR"
echo "3" > "$TEST_STATE_DIR/counter"

# Run hook from within _FAKE_ROOT so its `git rev-parse --show-toplevel`
# returns _FAKE_ROOT, producing a STATE_DIR that doesn't touch the real repo.
output=$(echo '{"tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":{"stdout":"All tests passed","stderr":""}}' | (cd "$_FAKE_ROOT" && bash "$TRACK_HOOK" 2>/dev/null))
counter_after=$(cat "$TEST_STATE_DIR/counter" 2>/dev/null || echo "missing")
assert_eq "track-cascade: passing test resets counter" "0" "$counter_after"

# Malformed JSON — should exit gracefully
output=$(echo 'not valid json at all' | bash "$TRACK_HOOK" 2>/dev/null)
assert_eq "track-cascade: malformed JSON exits gracefully" "{}" "$output"

# -----------------------------------------------------------------------
# Test 3: check-validation-failures.sh field extraction
# -----------------------------------------------------------------------
echo ""
echo "--- check-validation-failures.sh field extraction ---"

CHECK_HOOK="$DSO_PLUGIN_DIR/hooks/check-validation-failures.sh"

# Non-Bash tool should exit silently
output=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$CHECK_HOOK" 2>/dev/null)
assert_eq "check-validation: non-Bash exits silently" "{}" "$output"

# Bash tool with non-validate command should exit silently
output=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | bash "$CHECK_HOOK" 2>/dev/null)
assert_eq "check-validation: non-validate command exits silently" "{}" "$output"

# Bash tool with validate.sh command but no failures — should exit silently
output=$(echo '{"tool_name":"Bash","tool_input":{"command":"validate.sh --ci"},"tool_response":{"stdout":"All checks passed"}}' | bash "$CHECK_HOOK" 2>/dev/null)
assert_eq "check-validation: no failures exits silently" "{}" "$output"

# Malformed JSON — should exit gracefully
output=$(echo 'broken json {{{' | bash "$CHECK_HOOK" 2>/dev/null)
assert_eq "check-validation: malformed JSON exits gracefully" "{}" "$output"

# -----------------------------------------------------------------------
# Test 4: pre-bash-functions.sh hook_commit_failure_tracker field extraction
# -----------------------------------------------------------------------
echo ""
echo "--- hook_commit_failure_tracker field extraction ---"

source "$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

# Non-Bash tool should return 0
hook_commit_failure_tracker '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' 2>/dev/null
assert_eq "commit-tracker: non-Bash returns 0" "0" "$?"

# Bash tool with non-commit command should return 0
hook_commit_failure_tracker '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' 2>/dev/null
assert_eq "commit-tracker: non-commit returns 0" "0" "$?"

# Malformed JSON — should return 0 (non-blocking)
hook_commit_failure_tracker 'not json' 2>/dev/null
assert_eq "commit-tracker: malformed JSON returns 0" "0" "$?"

# -----------------------------------------------------------------------
# Test 5: no jq calls remain in target files
# -----------------------------------------------------------------------
echo ""
echo "--- no jq calls remain ---"

jq_in_track=$(grep -cE '^\s*(check_tool jq|.*\| jq |jq -)' "$TRACK_HOOK" 2>/dev/null || true)
jq_in_track=${jq_in_track:-0}
assert_eq "track-cascade: zero jq calls" "0" "$jq_in_track"

jq_in_check=$(grep -cE '^\s*(check_tool jq|.*\| jq |jq -)' "$CHECK_HOOK" 2>/dev/null || true)
jq_in_check=${jq_in_check:-0}
assert_eq "check-validation: zero jq calls" "0" "$jq_in_check"

PRE_BASH="$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"
jq_in_prebash=$(grep -cE '(check_tool jq|.*\| jq |jq -)' "$PRE_BASH" 2>/dev/null || true)
jq_in_prebash=${jq_in_prebash:-0}
assert_eq "pre-bash-functions: zero jq calls" "0" "$jq_in_prebash"

print_summary
