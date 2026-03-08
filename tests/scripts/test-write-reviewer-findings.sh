#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-write-reviewer-findings.sh
# Tests for lockpick-workflow/scripts/write-reviewer-findings.sh
#
# Verifies the validate-then-write gate for reviewer-findings.json:
#   - Valid JSON produces a hash and writes findings file
#   - Invalid JSON is rejected (exit 1, no file written)
#   - Empty input is rejected (exit 2)
#   - Out-of-range scores are rejected
#   - Script sources deps.sh for get_artifacts_dir()

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

echo "=== test-write-reviewer-findings.sh ==="

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/write-reviewer-findings.sh"

# Resolve artifacts dir once, before any script invocations
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)

# Clean up any leftover findings from previous runs
trap 'rm -f "$ARTIFACTS_DIR/reviewer-findings.json" "$ARTIFACTS_DIR/reviewer-findings-pending.json"' EXIT

# Valid findings JSON
VALID_JSON='{
  "scores": {
    "code_hygiene": 5,
    "object_oriented_design": "N/A",
    "readability": 4,
    "functionality": 4,
    "testing_coverage": 5
  },
  "findings": [
    {
      "severity": "minor",
      "category": "readability",
      "description": "Test finding",
      "file": "test.py"
    }
  ],
  "summary": "Test summary for validation."
}'

# Invalid JSON (missing required score dimensions)
INVALID_JSON='{
  "scores": {
    "code_hygiene": 5
  },
  "findings": [],
  "summary": "Incomplete scores"
}'

# Invalid JSON (out-of-range score value)
OUT_OF_RANGE_JSON='{
  "scores": {
    "code_hygiene": 5,
    "object_oriented_design": "N/A",
    "readability": 10,
    "functionality": 4,
    "testing_coverage": 5
  },
  "findings": [],
  "summary": "Score 10 is out of range (max is 5)."
}'

# test_script_exists
# The plugin script must exist and be executable.
if [[ -x "$SCRIPT" ]]; then
    actual="executable"
else
    actual="not_executable"
fi
assert_eq "test_script_exists" "executable" "$actual"

# test_script_sources_deps
# Script must source deps.sh (not hardcode artifact paths).
if grep -q 'deps\.sh' "$SCRIPT"; then
    actual="sources_deps"
else
    actual="no_deps"
fi
assert_eq "test_script_sources_deps" "sources_deps" "$actual"

# test_script_uses_get_artifacts_dir
# Script must use get_artifacts_dir() instead of hardcoded paths.
if grep -q 'get_artifacts_dir' "$SCRIPT"; then
    actual="uses_function"
else
    actual="hardcoded"
fi
assert_eq "test_script_uses_get_artifacts_dir" "uses_function" "$actual"

# test_valid_json_produces_hash
# Piping valid JSON should exit 0 and output a SHA-256 hash.
hash_output=$(echo "$VALID_JSON" | "$SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
assert_eq "test_valid_json_exit_code" "0" "$exit_code"

# Hash should be a 64-character hex string
hash_len=${#hash_output}
assert_eq "test_valid_json_hash_length" "64" "$hash_len"

# test_valid_json_writes_findings_file
# After valid input, reviewer-findings.json should exist in the artifacts dir.
if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_valid_json_writes_findings_file" "exists" "$actual"

# Clean up before next test
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"

# test_invalid_json_rejected
# Piping invalid JSON (incomplete scores) should exit non-zero.
echo "$INVALID_JSON" | "$SCRIPT" 2>/dev/null && exit_code=0 || exit_code=$?
assert_eq "test_invalid_json_rejected" "1" "$exit_code"

# test_out_of_range_score_rejected
# Piping JSON with score=10 (outside 1-5 range) should exit non-zero.
echo "$OUT_OF_RANGE_JSON" | "$SCRIPT" 2>/dev/null && exit_code=0 || exit_code=$?
assert_eq "test_out_of_range_score_rejected" "1" "$exit_code"

# test_empty_input_rejected
# Piping truly empty input (no bytes) should exit 2.
printf "" | "$SCRIPT" 2>/dev/null && exit_code=0 || exit_code=$?
assert_eq "test_empty_input_rejected" "2" "$exit_code"

# test_no_pending_file_on_failure
# After a failed validation, no pending file should remain.
if [[ -f "$ARTIFACTS_DIR/reviewer-findings-pending.json" ]]; then
    actual="pending_exists"
else
    actual="no_pending"
fi
assert_eq "test_no_pending_file_on_failure" "no_pending" "$actual"

print_summary
