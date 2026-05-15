#!/usr/bin/env bash
# tests/agents/test-validate-verifier-output.sh
# RED structural tests for validate-verifier-output.sh
# Testing Mode: RED — fails until S3 T3 creates the script

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/validate-verifier-output.sh"

write_verifier_fixture() {
    local name="$1" content="$2"
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/verifier-fixture-${name}.XXXXXX")
    printf '%s' "$content" > "$f"
    echo "$f"
}

# test_verifier_script_exists
echo "--- test_verifier_script_exists ---"
_snapshot_fail
_script_exists="missing"
[[ -f "$VALIDATE_SCRIPT" ]] && _script_exists="present"
assert_eq "test_verifier_script_exists: script file exists" "present" "$_script_exists"
assert_pass_if_clean "test_verifier_script_exists"

# test_valid_fingerprint_accepted
# Valid fingerprint: path/file.py:42-42
echo "--- test_valid_fingerprint_accepted ---"
_snapshot_fail
_FP_VALID=$(write_verifier_fixture "valid_fp" '{"rulings":[{"finding_id":"f-001","ruling":"confirm","fingerprint":"src/app.py:42-42","verifier_status":"verified","rationale":"The code exists and is correct"}]}')
bash "$VALIDATE_SCRIPT" "$_FP_VALID" >/dev/null 2>&1
assert_eq "test_valid_fingerprint_accepted: exits 0 for valid fingerprint" "0" "$?"
rm -f "$_FP_VALID"
assert_pass_if_clean "test_valid_fingerprint_accepted"

# test_valid_multi_line_fingerprint_accepted
# Multi-line fingerprint: path/file.py:10-25
echo "--- test_valid_multi_line_fingerprint_accepted ---"
_snapshot_fail
_FP_MULTI=$(write_verifier_fixture "multi_fp" '{"rulings":[{"finding_id":"f-002","ruling":"drop","fingerprint":"src/utils.py:10-25","verifier_status":"verified","rationale":"Finding was incorrect, code present"}]}')
bash "$VALIDATE_SCRIPT" "$_FP_MULTI" >/dev/null 2>&1
assert_eq "test_valid_multi_line_fingerprint_accepted: exits 0 for multi-line fingerprint" "0" "$?"
rm -f "$_FP_MULTI"
assert_pass_if_clean "test_valid_multi_line_fingerprint_accepted"

# test_zero_sentinel_fingerprint_accepted
# 0-0 sentinel for missing line anchor
echo "--- test_zero_sentinel_fingerprint_accepted ---"
_snapshot_fail
_FP_ZERO=$(write_verifier_fixture "zero_fp" '{"rulings":[{"finding_id":"f-003","ruling":"confirm","fingerprint":"src/app.py:0-0","verifier_status":"verified","rationale":"No specific line anchor available"}]}')
bash "$VALIDATE_SCRIPT" "$_FP_ZERO" >/dev/null 2>&1
assert_eq "test_zero_sentinel_fingerprint_accepted: exits 0 for 0-0 sentinel" "0" "$?"
rm -f "$_FP_ZERO"
assert_pass_if_clean "test_zero_sentinel_fingerprint_accepted"

# test_invalid_ruling_rejected
# ruling must be confirm, downgrade-to-minor, or drop
echo "--- test_invalid_ruling_rejected ---"
_snapshot_fail
_RULING_BAD=$(write_verifier_fixture "bad_ruling" '{"rulings":[{"finding_id":"f-004","ruling":"invalid-value","fingerprint":"src/app.py:1-1","verifier_status":"verified","rationale":"Test"}]}')
_RULING_BAD_EXIT=0
bash "$VALIDATE_SCRIPT" "$_RULING_BAD" >/dev/null 2>&1 || _RULING_BAD_EXIT=$?
assert_ne "test_invalid_ruling_rejected: exits non-zero for invalid ruling" "0" "$_RULING_BAD_EXIT"
rm -f "$_RULING_BAD"
assert_pass_if_clean "test_invalid_ruling_rejected"

# test_missing_rationale_rejected
echo "--- test_missing_rationale_rejected ---"
_snapshot_fail
_NO_RAT=$(write_verifier_fixture "no_rationale" '{"rulings":[{"finding_id":"f-005","ruling":"confirm","fingerprint":"src/app.py:1-1","verifier_status":"verified"}]}')
_NO_RAT_EXIT=0
bash "$VALIDATE_SCRIPT" "$_NO_RAT" >/dev/null 2>&1 || _NO_RAT_EXIT=$?
assert_ne "test_missing_rationale_rejected: exits non-zero when rationale missing" "0" "$_NO_RAT_EXIT"
rm -f "$_NO_RAT"
assert_pass_if_clean "test_missing_rationale_rejected"

print_summary
