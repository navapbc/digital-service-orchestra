#!/usr/bin/env bash
# lockpick-workflow/tests/test_deps_json_helpers.sh
# Unit tests for JSON helper functions in deps.sh:
#   parse_json_object, json_build, json_mutate, json_filter_jsonl, json_summarize_input
#
# Usage: bash lockpick-workflow/tests/test_deps_json_helpers.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

PASS=0
FAIL=0

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$label" "$expected" "$actual" >&2
    fi
}

assert_contains() {
    local label="$1" substring="$2" actual="$3"
    if [[ "$actual" == *"$substring"* ]]; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s\n  expected to contain: %s\n  actual: %s\n" "$label" "$substring" "$actual" >&2
    fi
}

assert_valid_json() {
    local label="$1" json_str="$2"
    if echo "$json_str" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        (( PASS++ ))
    else
        (( FAIL++ ))
        printf "FAIL: %s\n  not valid JSON: %s\n" "$label" "$json_str" >&2
    fi
}

# ============================================================================
# parse_json_object
# ============================================================================
echo "=== parse_json_object ==="

INPUT='{"tool_name":"Bash","tool_input":{"command":"git status","file_path":"/tmp/test.txt"}}'
RESULT=$(parse_json_object "$INPUT" '.tool_input')
assert_eq "extract tool_input object" '{"command":"git status","file_path":"/tmp/test.txt"}' "$RESULT"

# Nested objects
INPUT2='{"a":{"b":{"c":1},"d":2},"e":3}'
RESULT2=$(parse_json_object "$INPUT2" '.a')
assert_eq "extract nested object" '{"b":{"c":1},"d":2}' "$RESULT2"

# Missing field returns empty
RESULT3=$(parse_json_object "$INPUT" '.nonexistent')
assert_eq "missing field returns empty" "" "$RESULT3"

# Empty object
INPUT4='{"tool_name":"X","tool_input":{}}'
RESULT4=$(parse_json_object "$INPUT4" '.tool_input')
assert_eq "extract empty object" '{}' "$RESULT4"

# Object with string values containing braces
INPUT5='{"data":{"msg":"hello {world}","x":1}}'
RESULT5=$(parse_json_object "$INPUT5" '.data')
assert_eq "object with braces in string" '{"msg":"hello {world}","x":1}' "$RESULT5"

# ============================================================================
# json_build
# ============================================================================
echo "=== json_build ==="

# Basic string and numeric fields
RESULT=$(json_build ts="2026-01-01" count:n=42)
assert_valid_json "json_build produces valid JSON" "$RESULT"
# Verify via python
PARSED=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ts'], type(d['count']).__name__, d['count'])")
assert_eq "json_build values" "2026-01-01 int 42" "$PARSED"

# Empty value
RESULT2=$(json_build key="")
assert_valid_json "json_build empty value" "$RESULT2"
PARSED2=$(echo "$RESULT2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['key'])")
assert_eq "json_build empty string value" "" "$PARSED2"

# Special characters: quotes
RESULT3=$(json_build msg='hello "world"')
assert_valid_json "json_build with quotes" "$RESULT3"
PARSED3=$(echo "$RESULT3" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['msg'])")
assert_eq "json_build escapes quotes" 'hello "world"' "$PARSED3"

# Special characters: backslashes
RESULT4=$(json_build path='C:\Users\test')
assert_valid_json "json_build with backslashes" "$RESULT4"
PARSED4=$(echo "$RESULT4" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['path'])")
assert_eq "json_build escapes backslashes" 'C:\Users\test' "$PARSED4"

# Special characters: newlines
RESULT5=$(json_build msg=$'line1\nline2')
assert_valid_json "json_build with newlines" "$RESULT5"
PARSED5=$(echo "$RESULT5" | python3 -c "import json,sys; d=json.load(sys.stdin); print(repr(d['msg']))")
assert_eq "json_build escapes newlines" "'line1\\nline2'" "$PARSED5"

# Multiple numeric fields
RESULT6=$(json_build a:n=1 b:n=2.5 c="text")
assert_valid_json "json_build mixed types" "$RESULT6"

# Boolean-like numeric values
RESULT7=$(json_build flag:n=0 active:n=1)
assert_valid_json "json_build boolean-like numerics" "$RESULT7"

# Single field
RESULT8=$(json_build name="test")
assert_eq "json_build single field" '{"name":"test"}' "$RESULT8"

# ============================================================================
# json_mutate
# ============================================================================
echo "=== json_mutate ==="

# Basic mutation from stdin
RESULT=$(echo '{"a":1}' | json_mutate 'data["b"]=2')
assert_valid_json "json_mutate produces valid JSON" "$RESULT"
PARSED=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('a'), d.get('b'))")
assert_eq "json_mutate adds field" "1 2" "$PARSED"

# Mutation from file
TMPFILE=$(mktemp)
_CLEANUP_DIRS+=("$TMPFILE")
echo '{"x":10,"y":20}' > "$TMPFILE"
RESULT2=$(json_mutate 'data["z"]=data["x"]+data["y"]' "$TMPFILE")
rm -f "$TMPFILE"
PARSED2=$(echo "$RESULT2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('z'))")
assert_eq "json_mutate from file" "30" "$PARSED2"

# Delete a field
RESULT3=$(echo '{"a":1,"b":2,"c":3}' | json_mutate 'del data["b"]')
PARSED3=$(echo "$RESULT3" | python3 -c "import json,sys; d=json.load(sys.stdin); print('b' in d)")
assert_eq "json_mutate delete field" "False" "$PARSED3"

# Empty input
RESULT4=$(echo '{}' | json_mutate 'data["new"]=42')
PARSED4=$(echo "$RESULT4" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('new'))")
assert_eq "json_mutate on empty object" "42" "$PARSED4"

# ============================================================================
# json_filter_jsonl
# ============================================================================
echo "=== json_filter_jsonl ==="

TMPJSONL=$(mktemp)
_CLEANUP_DIRS+=("$TMPJSONL")
cat > "$TMPJSONL" <<'JSONL'
{"name":"alice","age":30}
{"name":"bob","age":25}
{"name":"charlie","age":35}
JSONL

# Filter by age > 28
RESULT=$(json_filter_jsonl "$TMPJSONL" 'data.get("age",0)>28')
LINE_COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
assert_eq "json_filter_jsonl count" "2" "$LINE_COUNT"
assert_contains "json_filter_jsonl includes alice" "alice" "$RESULT"
assert_contains "json_filter_jsonl includes charlie" "charlie" "$RESULT"

# Filter with no matches
RESULT2=$(json_filter_jsonl "$TMPJSONL" 'data.get("age",0)>100')
assert_eq "json_filter_jsonl no matches" "" "$RESULT2"

# Filter matching all
RESULT3=$(json_filter_jsonl "$TMPJSONL" 'data.get("age",0)>0')
LINE_COUNT3=$(echo "$RESULT3" | wc -l | tr -d ' ')
assert_eq "json_filter_jsonl all match" "3" "$LINE_COUNT3"

rm -f "$TMPJSONL"

# Empty file
TMPEMPTY=$(mktemp)
_CLEANUP_DIRS+=("$TMPEMPTY")
> "$TMPEMPTY"
RESULT4=$(json_filter_jsonl "$TMPEMPTY" 'True')
assert_eq "json_filter_jsonl empty file" "" "$RESULT4"
rm -f "$TMPEMPTY"

# ============================================================================
# json_summarize_input
# ============================================================================
echo "=== json_summarize_input ==="

# Basic key=value summary
INPUT='{"command":"git status","file_path":"/tmp/test.txt"}'
RESULT=$(json_summarize_input "$INPUT")
assert_contains "summarize contains command" "command=" "$RESULT"
assert_contains "summarize contains file_path" "file_path=" "$RESULT"

# Long values should be truncated at 80 chars
LONG_VAL=$(python3 -c "print('x'*200)")
INPUT2=$(python3 -c "import json; print(json.dumps({'long_key': '$LONG_VAL'}))")
RESULT2=$(json_summarize_input "$INPUT2")
# Result should be much shorter than 200 chars for the value part
VAL_LEN=$(echo "$RESULT2" | python3 -c "import sys; s=sys.stdin.read().strip(); v=s.split('=',1)[1]; print(len(v))")
assert_eq "summarize truncates long values" "80" "$VAL_LEN"

# Empty object
RESULT3=$(json_summarize_input '{}')
assert_eq "summarize empty object" "" "$RESULT3"

# Null values
RESULT4=$(json_summarize_input '{"key":null}')
assert_contains "summarize null value" "key=null" "$RESULT4"

# Numeric values
RESULT5=$(json_summarize_input '{"count":42}')
assert_contains "summarize numeric" "count=42" "$RESULT5"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS passed, $FAIL failed (of $TOTAL)"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
