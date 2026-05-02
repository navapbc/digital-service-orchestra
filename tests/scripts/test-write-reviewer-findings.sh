#!/usr/bin/env bash
# tests/scripts/test-write-reviewer-findings.sh
# Tests for scripts/write-reviewer-findings.sh
#
# Verifies the validate-then-write gate for reviewer-findings.json:
#   - Valid 2-key JSON {findings:[...],summary:"..."} produces a hash and writes findings file
#   - 3-key JSON with scores key is rejected (exit non-zero)
#   - Invalid JSON is rejected (exit 1, no file written)
#   - Empty input is rejected (exit 2)
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

# Valid findings JSON — 2-key schema (findings + summary only, no scores)
VALID_JSON='{
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

# Invalid JSON (truly malformed — not valid JSON at all)
INVALID_JSON='this is not json'

# Invalid JSON (out-of-range score value — scores key present, should be rejected)
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

# test_out_of_range_score_deprecated
# Piping JSON with score=10 (outside 1-5 range) exits 0 — scores no longer validated,
# only deprecated with a warning. Invalid score values are tolerated during transition.
echo "$OUT_OF_RANGE_JSON" | "$SCRIPT" 2>/dev/null && exit_code=0 || exit_code=$?
assert_eq "test_out_of_range_score_deprecated: exits 0 (scores not validated during transition)" "0" "$exit_code"

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
# Piping valid 2-key JSON should exit 0 and produce a hash.
NEW_DIM_JSON='{
  "findings": [],
  "summary": "Two-key schema is valid."
}'
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
new_hash_output=$(echo "$NEW_DIM_JSON" | "$SCRIPT" 2>/dev/null) && new_exit_code=0 || new_exit_code=$?
assert_eq "test_write_new_dimension_names_accepted" "0" "$new_exit_code"

# ---------------------------------------------------------------------------
# --review-tier flag tests (RED: write-reviewer-findings.sh does not support
# --review-tier yet; these tests document the expected behaviour)
# ---------------------------------------------------------------------------
# REVIEW-DEFENSE: field_in_json tests assert review_tier as a top-level key.
# validate-review-output.sh accepts 2-key schema {findings, summary} and optionally
# review_tier / selected_tier injected by write-reviewer-findings.sh flags.
# These tests remain RED until write-reviewer-findings.sh implements --review-tier
# support AND validate-review-output.sh accepts review_tier as an additional key.
# The .test-index RED markers for these tests enforce that the test gate tolerates
# their current failure.

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

# ---------------------------------------------------------------------------
# --selected-tier flag tests (bug 21d7-b84a)
#
# write-reviewer-findings.sh must accept --selected-tier <light|standard|deep>
# and inject selected_tier as a top-level key. This carries the classifier's
# recommended tier into findings so record-review.sh can verify tier without
# depending on the separately-located classifier-telemetry.jsonl.
# ---------------------------------------------------------------------------

# test_selected_tier_deep_injected
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --selected-tier deep 2>/dev/null && sel_deep_exit=0 || sel_deep_exit=$?
assert_eq "test_selected_tier_deep_exit_code" "0" "$sel_deep_exit"

if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings.json')); assert d.get('selected_tier') == 'deep'" 2>/dev/null; then
        sel_deep_field="present"
    else
        sel_deep_field="missing_or_wrong"
    fi
else
    sel_deep_field="no_file"
fi
assert_eq "test_selected_tier_deep_field_in_json" "present" "$sel_deep_field"

# test_selected_tier_with_review_tier_both_fields
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --review-tier standard --selected-tier deep 2>/dev/null && sel_both_exit=0 || sel_both_exit=$?
assert_eq "test_selected_tier_both_fields_exit_code" "0" "$sel_both_exit"

if [[ -f "$ARTIFACTS_DIR/reviewer-findings.json" ]]; then
    if python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings.json')); assert d.get('review_tier')=='standard' and d.get('selected_tier')=='deep'" 2>/dev/null; then
        sel_both_fields="present"
    else
        sel_both_fields="missing_or_wrong"
    fi
else
    sel_both_fields="no_file"
fi
assert_eq "test_selected_tier_both_fields_in_json" "present" "$sel_both_fields"

# test_selected_tier_invalid_rejected
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$VALID_JSON" | "$SCRIPT" --selected-tier invalid 2>/dev/null && sel_inv_exit=0 || sel_inv_exit=$?
if [[ "$sel_inv_exit" -ne 0 ]]; then
    sel_inv_result="rejected"
else
    sel_inv_result="accepted"
fi
assert_eq "test_selected_tier_invalid_rejected" "rejected" "$sel_inv_result"

# ---------------------------------------------------------------------------
# End --selected-tier tests
# ---------------------------------------------------------------------------

# test_write_old_dimension_names_deprecated
# Piping JSON with scores key (3-key schema) exits 0 (scores tolerated during transition).
OLD_DIM_JSON='{
  "scores": {
    "invalid_dim_a": 4,
    "invalid_dim_b": 5,
    "invalid_dim_c": 4,
    "invalid_dim_d": 4,
    "invalid_dim_e": 5
  },
  "findings": [],
  "summary": "Scores key is deprecated but tolerated during transition."
}'
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"
echo "$OLD_DIM_JSON" | "$SCRIPT" 2>/dev/null && old_exit_code=0 || old_exit_code=$?
assert_eq "test_write_old_dimension_names_deprecated: exits 0 (scores tolerated during transition)" "0" "$old_exit_code"

# ---------------------------------------------------------------------------
# test_write_reviewer_two_key_schema_succeeds
# Piping a 2-key schema {findings:[...], summary:"..."} should exit 0 and output a hash.
# RED: fails until write-reviewer-findings.sh is updated to accept 2-key schema.
# ---------------------------------------------------------------------------
echo "=== test_write_reviewer_two_key_schema_succeeds ==="
TMPDIR_TEST=$(mktemp -d "${TMPDIR:-/tmp}/test-write-reviewer-XXXXXX")
trap 'rm -rf "$TMPDIR_TEST"' EXIT
RESULT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TMPDIR_TEST" bash -c 'echo '"'"'{"findings":[],"summary":"All checks passed."}'"'"' | '"\"$SCRIPT\""'' 2>/dev/null) && TWO_KEY_EXIT=0 || TWO_KEY_EXIT=$?
assert_eq "test_write_reviewer_two_key_schema_succeeds: exits 0" "0" "$TWO_KEY_EXIT"
assert_ne "test_write_reviewer_two_key_schema_succeeds: outputs a hash" "" "$RESULT"

# ---------------------------------------------------------------------------
# test_write_reviewer_scores_key_deprecated
# Piping 3-key schema with scores should exit 0 (scores tolerated with deprecation warning
# during transition until reviewer agents are updated in story f19a-c97e).
# ---------------------------------------------------------------------------
echo "=== test_write_reviewer_scores_key_deprecated ==="
TMPDIR_TEST2=$(mktemp -d "${TMPDIR:-/tmp}/test-write-reviewer2-XXXXXX")
trap 'rm -rf "$TMPDIR_TEST2"' EXIT
_STDERR_WRF=$(mktemp "${TMPDIR:-/tmp}/test-write-reviewer-stderr.XXXXXX")
THREE_KEY_EXIT=0
WORKFLOW_PLUGIN_ARTIFACTS_DIR="$TMPDIR_TEST2" bash -c 'echo '"'"'{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}'"'"' | '"\"$SCRIPT\""'' 2>"$_STDERR_WRF" || THREE_KEY_EXIT=$?
SCORES_STDERR=$(cat "$_STDERR_WRF"); rm -f "$_STDERR_WRF"
assert_eq "test_write_reviewer_scores_key_deprecated: exits 0 (scores tolerated during transition)" "0" "$THREE_KEY_EXIT"
assert_contains "test_write_reviewer_scores_key_deprecated: stderr contains DEPRECATION WARNING" "DEPRECATION WARNING" "$SCORES_STDERR"

# Clean up
rm -f "$ARTIFACTS_DIR/reviewer-findings.json"

print_summary
