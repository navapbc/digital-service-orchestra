#!/usr/bin/env bash
# tests/scripts/test-write-reviewer-findings.sh
# Tests for scripts/write-reviewer-findings.sh
#
# Verifies the validate-then-write gate for reviewer-findings.json:
#   - Valid JSON produces a hash and writes findings file
#   - Invalid JSON is rejected (exit 1, no file written)
#   - Empty input is rejected (exit 2)
#   - Out-of-range scores are rejected
#   - Script sources deps.sh for get_artifacts_dir()

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

echo "=== test-write-reviewer-findings.sh ==="

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SCRIPT="$DSO_PLUGIN_DIR/scripts/write-reviewer-findings.sh"

# Use an isolated temp directory so tests don't clobber production artifacts.
# Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so write-reviewer-findings.sh (via
# get_artifacts_dir()) uses this dir instead of the real one.
ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-write-findings-XXXXXX")
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR"

# Clean up temp directory on exit
trap 'rm -rf "$ARTIFACTS_DIR"' EXIT

# Valid findings JSON
VALID_JSON='{
  "scores": {
    "hygiene": 5,
    "design": "N/A",
    "maintainability": 4,
    "correctness": 5,
    "verification": 5
  },
  "findings": [
    {
      "severity": "minor",
      "category": "maintainability",
      "description": "Test finding",
      "file": "test.py"
    }
  ],
  "summary": "Test summary for validation."
}'

# Invalid JSON (missing required score dimensions)
INVALID_JSON='{
  "scores": {
    "hygiene": 5
  },
  "findings": [],
  "summary": "Incomplete scores"
}'

# Invalid JSON (out-of-range score value)
OUT_OF_RANGE_JSON='{
  "scores": {
    "hygiene": 5,
    "design": "N/A",
    "maintainability": 10,
    "correctness": 5,
    "verification": 5
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

# test_write_new_dimension_names_accepted
# Piping valid JSON with NEW dimension names should exit 0 and produce a hash.
# RED: fails until Task w22-4391 renames the dimension keys in the validator.
NEW_DIM_JSON='{
  "scores": {
    "correctness": 5,
    "verification": 5,
    "hygiene": 5,
    "design": 5,
    "maintainability": 5
  },
  "findings": [],
  "summary": "New dimension names are valid after the rename."
}'
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
new_hash_output=$(echo "$NEW_DIM_JSON" | "$SCRIPT" 2>/dev/null) && new_exit_code=0 || new_exit_code=$?
assert_eq "test_write_new_dimension_names_accepted" "0" "$new_exit_code"

# test_dimensions_key_normalized_to_scores
# Piping JSON with 'dimensions' top-level key (instead of 'scores') should succeed
# after normalization — the script should rename 'dimensions' to 'scores' before validation.
DIMENSIONS_KEY_JSON='{
  "dimensions": {
    "hygiene": 5,
    "design": "N/A",
    "maintainability": 4,
    "correctness": 5,
    "verification": 5
  },
  "findings": [
    {
      "severity": "minor",
      "category": "maintainability",
      "description": "Test finding with dimensions key",
      "file": "test.py"
    }
  ],
  "summary": "Test that dimensions key gets normalized to scores."
}'
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
dim_hash_output=$(echo "$DIMENSIONS_KEY_JSON" | "$SCRIPT" 2>/dev/null) && dim_exit_code=0 || dim_exit_code=$?
assert_eq "test_dimensions_key_normalized_exit_code" "0" "$dim_exit_code"

# After normalization, the written file should contain 'scores' key, not 'dimensions'
if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings.json')); assert 'scores' in d and 'dimensions' not in d" 2>/dev/null; then
        actual="scores_key"
    else
        actual="wrong_key"
    fi
else
    actual="no_file"
fi
assert_eq "test_dimensions_key_normalized_to_scores" "scores_key" "$actual"

# Clean up
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"

# ---------------------------------------------------------------------------
# --review-tier flag tests (RED: write-reviewer-findings.sh does not support
# --review-tier yet; these tests document the expected behaviour)
# ---------------------------------------------------------------------------
# REVIEW-DEFENSE: field_in_json tests assert review_tier as a top-level key.
# validate-review-output.sh currently enforces exactly 3 top-level keys. This
# is intentional TDD RED state — the GREEN implementation task will add
# --review-tier support to write-reviewer-findings.sh AND update
# validate-review-output.sh schema to accept review_tier as a 4th top-level
# key. Both changes are scoped to the same GREEN task, ensuring the validator
# contract and writer output stay in sync. The .test-index RED markers for
# these tests enforce that the test gate tolerates their current failure.

# test_review_tier_light_accepted
# --review-tier light should exit 0 and produce a review_tier field in the output JSON.
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier light 2>/dev/null && tier_light_exit=0 || tier_light_exit=$?
assert_eq "test_review_tier_light_exit_code" "0" "$tier_light_exit"

if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings.json')); assert d.get('review_tier') == 'light'" 2>/dev/null; then
        tier_light_field="present"
    else
        tier_light_field="missing_or_wrong"
    fi
else
    tier_light_field="no_file"
fi
assert_eq "test_review_tier_light_field_in_json" "present" "$tier_light_field"

# test_review_tier_standard_accepted
# --review-tier standard should exit 0.
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier standard 2>/dev/null && tier_std_exit=0 || tier_std_exit=$?
assert_eq "test_review_tier_standard_exit_code" "0" "$tier_std_exit"

if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings.json')); assert d.get('review_tier') == 'standard'" 2>/dev/null; then
        tier_std_field="present"
    else
        tier_std_field="missing_or_wrong"
    fi
else
    tier_std_field="no_file"
fi
assert_eq "test_review_tier_standard_field_in_json" "present" "$tier_std_field"

# test_review_tier_deep_accepted
# --review-tier deep should exit 0.
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier deep 2>/dev/null && tier_deep_exit=0 || tier_deep_exit=$?
assert_eq "test_review_tier_deep_exit_code" "0" "$tier_deep_exit"

if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings.json')); assert d.get('review_tier') == 'deep'" 2>/dev/null; then
        tier_deep_field="present"
    else
        tier_deep_field="missing_or_wrong"
    fi
else
    tier_deep_field="no_file"
fi
assert_eq "test_review_tier_deep_field_in_json" "present" "$tier_deep_field"

# test_review_tier_invalid_rejected
# --review-tier invalid should exit non-zero.
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier invalid 2>/dev/null && tier_inv_exit=0 || tier_inv_exit=$?
if [[ "$tier_inv_exit" -ne 0 ]]; then
    tier_inv_result="rejected"
else
    tier_inv_result="accepted"
fi
assert_eq "test_review_tier_invalid_rejected" "rejected" "$tier_inv_result"

# test_review_tier_wrong_case_Deep_rejected
# --review-tier Deep (wrong case) should exit non-zero — enum is lowercase only.
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier Deep 2>/dev/null && tier_deep_case_exit=0 || tier_deep_case_exit=$?
if [[ "$tier_deep_case_exit" -ne 0 ]]; then
    tier_deep_case_result="rejected"
else
    tier_deep_case_result="accepted"
fi
assert_eq "test_review_tier_wrong_case_Deep_rejected" "rejected" "$tier_deep_case_result"

# test_review_tier_wrong_case_LIGHT_rejected
# --review-tier LIGHT (wrong case) should exit non-zero — enum is lowercase only.
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier LIGHT 2>/dev/null && tier_light_case_exit=0 || tier_light_case_exit=$?
if [[ "$tier_light_case_exit" -ne 0 ]]; then
    tier_light_case_result="rejected"
else
    tier_light_case_result="accepted"
fi
assert_eq "test_review_tier_wrong_case_LIGHT_rejected" "rejected" "$tier_light_case_result"

# ---------------------------------------------------------------------------
# End --review-tier tests
# ---------------------------------------------------------------------------

# test_write_old_dimension_names_rejected
# Piping JSON with OLD dimension names should exit 1 (validator rejects them).
OLD_DIM_JSON='{
  "scores": {
    "invalid_dim_a": 4,
    "invalid_dim_b": 5,
    "invalid_dim_c": 4,
    "invalid_dim_d": 4,
    "invalid_dim_e": 5
  },
  "findings": [],
  "summary": "Unknown dimension names should be rejected by the validator."
}'
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$OLD_DIM_JSON" | "$SCRIPT" 2>/dev/null && old_exit_code=0 || old_exit_code=$?
assert_eq "test_write_old_dimension_names_rejected" "1" "$old_exit_code"

# ---------------------------------------------------------------------------
# test_dimensions_nested_scores_normalized (bug 8e5d-ade1)
# LLM sometimes writes { "dimensions": { "correctness": { "score": 4, "rationale": "..." } } }
# (nested object per dimension) instead of flat integers.
# The normalizer should handle both: rename 'dimensions'→'scores' AND flatten
# nested { "score": N } objects to integers.
# ---------------------------------------------------------------------------
NESTED_DIM_JSON='{
  "dimensions": {
    "hygiene": { "score": 5, "rationale": "Clean code" },
    "design": { "score": 5, "rationale": "Good structure" },
    "maintainability": { "score": 5, "rationale": "Easy to maintain" },
    "correctness": { "score": 5, "rationale": "Correct logic" },
    "verification": { "score": 5, "rationale": "Well tested" }
  },
  "findings": [],
  "summary": "Test that nested dimension score objects are flattened to integers."
}'
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
nested_dim_exit=1
nested_dim_output=$(echo "$NESTED_DIM_JSON" | "$SCRIPT" 2>/dev/null) && nested_dim_exit=0 || true
assert_eq "test_dimensions_nested_scores_normalized_exit_code" "0" "$nested_dim_exit"

if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "
import json
d = json.load(open('$ARTIFACTS_DIR/reviewer-findings.json'))
# Must have 'scores' not 'dimensions'
assert 'scores' in d and 'dimensions' not in d, 'dimensions key not renamed'
# All score values must be integers, not objects
for k, v in d['scores'].items():
    assert isinstance(v, int), f'{k} is {type(v).__name__}, expected int'
" 2>/dev/null; then
        nested_dim_schema="valid"
    else
        nested_dim_schema="invalid"
    fi
else
    nested_dim_schema="no_file"
fi
assert_eq "test_dimensions_nested_scores_normalized_schema" "valid" "$nested_dim_schema"

# Clean up
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"

print_summary
