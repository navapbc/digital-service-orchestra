#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-ci-status-no-jq.sh
# Tests that ci-status.sh JSON parsing works without jq by falling back to
# parse_json_field from deps.sh.
#
# Test strategy:
#   1. Create a mock jq that always fails (exits 1)
#   2. Put it first in PATH
#   3. Source deps.sh and verify the ci_parse_json helper works for simple fields
#   4. Verify the fallback warning is emitted to stderr when jq is unavailable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-ci-status-no-jq ==="

# ---------------------------------------------------------------------------
# Setup: create a mock jq that always fails so we can test fallback behaviour
# ---------------------------------------------------------------------------
MOCK_BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN_DIR"' EXIT

cat > "$MOCK_BIN_DIR/jq" <<'EOF'
#!/bin/bash
# Mock jq that always fails (simulates jq not being installed)
exit 1
EOF
chmod +x "$MOCK_BIN_DIR/jq"

# Save original PATH so we can restore it
ORIGINAL_PATH="$PATH"

# ---------------------------------------------------------------------------
# Load the helpers from ci-status.sh in isolation.
# We source deps.sh (for parse_json_field) and then define ci_parse_json
# the same way ci-status.sh does. This lets us unit-test the helper without
# running ci-status.sh's main body (which needs gh CLI).
# ---------------------------------------------------------------------------
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# Source the ci_parse_json function from ci-status.sh.
# We do this by extracting it: temporarily run the script with a sentinel
# that causes it to source deps.sh and export the function, then exit.
# Simpler approach: define ci_parse_json here the same way it will be defined
# in ci-status.sh, and test that implementation.
#
# The function contract:
#   ci_parse_json <json> <field_expr>
#   - tries jq -r '<field_expr>' on the json
#   - falls back to parse_json_field when jq fails
#   - emits "ci-status: jq not found, using parse_json_field fallback" to stderr
#     (only once — subsequent calls are silent)

# Replicate the helper definition (matching what ci-status.sh will define)
_CI_JQ_WARNED=0
ci_parse_json() {
    local json="$1"
    local expr="$2"
    local result
    result=$(echo "$json" | jq -r "$expr" 2>/dev/null)
    if [ $? -ne 0 ]; then
        if [ "$_CI_JQ_WARNED" -eq 0 ]; then
            echo "ci-status: jq not found, using parse_json_field fallback" >&2
            _CI_JQ_WARNED=1
        fi
        result=$(parse_json_field "$json" "$expr")
    fi
    echo "$result"
}

# ---------------------------------------------------------------------------
# Sample JSON matching GitHub Actions API response format (gh run list output)
# ---------------------------------------------------------------------------
SAMPLE_RUN_JSON='{
  "databaseId": 12345678,
  "status": "completed",
  "conclusion": "success",
  "name": "CI",
  "startedAt": "2026-03-15T10:00:00Z",
  "createdAt": "2026-03-15T09:59:00Z"
}'

SAMPLE_RUN_JSON_FAILURE='{
  "databaseId": 87654321,
  "status": "completed",
  "conclusion": "failure",
  "name": "CI",
  "startedAt": "2026-03-15T10:00:00Z",
  "createdAt": "2026-03-15T09:59:00Z"
}'

SAMPLE_RUN_JSON_INPROGRESS='{
  "databaseId": 11111111,
  "status": "in_progress",
  "conclusion": null,
  "name": "CI",
  "startedAt": "2026-03-15T10:00:00Z",
  "createdAt": "2026-03-15T09:59:00Z"
}'

# ---------------------------------------------------------------------------
# Test group 1: With real jq available — ensure the helper works normally
# ---------------------------------------------------------------------------
echo ""
echo "--- ci_parse_json: with real jq ---"

if command -v jq &>/dev/null; then
    result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.status')
    assert_eq "ci_parse_json .status (jq)" "completed" "$result"

    result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.conclusion')
    assert_eq "ci_parse_json .conclusion (jq)" "success" "$result"

    result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.name')
    assert_eq "ci_parse_json .name (jq)" "CI" "$result"
else
    echo "  (jq not installed on this system — skipping jq-present tests)"
fi

# ---------------------------------------------------------------------------
# Test group 2: With mock jq (always fails) — fallback to parse_json_field
# ---------------------------------------------------------------------------
echo ""
echo "--- ci_parse_json: fallback when jq fails ---"

# Reset warning state for each sub-test
_CI_JQ_WARNED=0

# Put the mock jq first in PATH
PATH="$MOCK_BIN_DIR:$ORIGINAL_PATH"

result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.status')
assert_eq "fallback .status" "completed" "$result"

result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.conclusion')
assert_eq "fallback .conclusion" "success" "$result"

result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.name')
assert_eq "fallback .name" "CI" "$result"

# Test with failure conclusion
result=$(ci_parse_json "$SAMPLE_RUN_JSON_FAILURE" '.status')
assert_eq "fallback .status (failure run)" "completed" "$result"

result=$(ci_parse_json "$SAMPLE_RUN_JSON_FAILURE" '.conclusion')
assert_eq "fallback .conclusion (failure)" "failure" "$result"

# Test in_progress run
result=$(ci_parse_json "$SAMPLE_RUN_JSON_INPROGRESS" '.status')
assert_eq "fallback .status (in_progress)" "in_progress" "$result"

# databaseId is a numeric field — parse_json_field handles non-string values
result=$(ci_parse_json "$SAMPLE_RUN_JSON" '.databaseId')
assert_eq "fallback .databaseId (numeric)" "12345678" "$result"

# Restore PATH
PATH="$ORIGINAL_PATH"

# ---------------------------------------------------------------------------
# Test group 3: Warning message is emitted to stderr when jq fails
# ---------------------------------------------------------------------------
echo ""
echo "--- ci_parse_json: warning emitted to stderr ---"

_CI_JQ_WARNED=0
PATH="$MOCK_BIN_DIR:$ORIGINAL_PATH"

stderr_output=$(ci_parse_json "$SAMPLE_RUN_JSON" '.status' 2>&1 >/dev/null)
assert_contains "fallback warning message" "ci-status: jq not found, using parse_json_field fallback" "$stderr_output"

# The warning is emitted — verify it contains the expected text
assert_contains "fallback warning contains 'parse_json_field fallback'" "parse_json_field fallback" "$stderr_output"

PATH="$ORIGINAL_PATH"

# ---------------------------------------------------------------------------
# Test group 4: ci-status.sh sources deps.sh and uses ci_parse_json
#   Verify by inspecting the script for the expected function/source pattern.
#   (We can't run the full script without gh CLI)
# ---------------------------------------------------------------------------
echo ""
echo "--- ci-status.sh: contains ci_parse_json and sources deps.sh ---"

CI_STATUS_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/ci-status.sh"

# Check that deps.sh is sourced
deps_sourced=$(grep -c 'deps\.sh' "$CI_STATUS_SCRIPT" 2>/dev/null || echo "0")
assert_ne "ci-status.sh sources deps.sh" "0" "$deps_sourced"

# Check that ci_parse_json function is defined
ci_parse_json_defined=$(grep -c 'ci_parse_json()' "$CI_STATUS_SCRIPT" 2>/dev/null || echo "0")
assert_ne "ci-status.sh defines ci_parse_json" "0" "$ci_parse_json_defined"

# Check that fallback warning text is present
warning_present=$(grep -c 'jq not found, using parse_json_field fallback' "$CI_STATUS_SCRIPT" 2>/dev/null || echo "0")
assert_ne "ci-status.sh has fallback warning" "0" "$warning_present"

# Check that direct jq pipes for simple field extraction are replaced
# (the simple field extractions like `| jq -r '.status'` should be gone)
simple_jq_calls=$(grep -E "\| jq -r '\.[a-zA-Z]+'" "$CI_STATUS_SCRIPT" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "ci-status.sh: no simple-field jq -r calls remaining" "0" "$simple_jq_calls"

print_summary
