#!/usr/bin/env bash
# tests/scripts/test-record-review-verifier-fields.sh
# RED structural tests for verifier field tolerance in record-review.sh and contract docs.
# Testing Mode: RED — fails until S8 T2 updates record-review.sh and reviewer-findings contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

REVIEWER_FINDINGS_SCHEMA="$PLUGIN_ROOT/plugins/dso/docs/contracts/reviewer-findings.md"
RECORD_REVIEW_SH="$PLUGIN_ROOT/plugins/dso/scripts/record-review.sh"
MIRROR_DEFENSES_SH="$PLUGIN_ROOT/plugins/dso/scripts/mirror-defenses-to-pr.sh"

# test_reviewer_findings_contract_lists_verifier_status
echo "--- test_reviewer_findings_contract_lists_verifier_status ---"
_snapshot_fail
grep -q "verifier_status" "$REVIEWER_FINDINGS_SCHEMA" 2>/dev/null
assert_eq "test_reviewer_findings_contract_lists_verifier_status: verifier_status in schema" "0" "$?"
assert_pass_if_clean "test_reviewer_findings_contract_lists_verifier_status"

# test_reviewer_findings_contract_lists_evidence_invalidated
echo "--- test_reviewer_findings_contract_lists_evidence_invalidated ---"
_snapshot_fail
grep -q "evidence_invalidated" "$REVIEWER_FINDINGS_SCHEMA" 2>/dev/null
assert_eq "test_reviewer_findings_contract_lists_evidence_invalidated: evidence_invalidated in schema" "0" "$?"
assert_pass_if_clean "test_reviewer_findings_contract_lists_evidence_invalidated"

# test_reviewer_findings_contract_lists_fingerprint
echo "--- test_reviewer_findings_contract_lists_fingerprint ---"
_snapshot_fail
grep -q "fingerprint" "$REVIEWER_FINDINGS_SCHEMA" 2>/dev/null
assert_eq "test_reviewer_findings_contract_lists_fingerprint: fingerprint in schema" "0" "$?"
assert_pass_if_clean "test_reviewer_findings_contract_lists_fingerprint"

# test_record_review_tolerates_verifier_status_field
# record-review.sh must NOT reject findings with unknown verifier_status field
# It should pass findings through or explicitly allowlist extra fields
echo "--- test_record_review_tolerates_verifier_status_field ---"
_snapshot_fail
# Check that record-review.sh either: (a) passes all fields through, or (b) explicitly mentions verifier_status tolerance
grep -qiE "verifier_status|extra.*field|additional.*field|unknown.*field|pass.*through|forward.?compat" "$RECORD_REVIEW_SH" 2>/dev/null
assert_eq "test_record_review_tolerates_verifier_status_field: record-review.sh tolerates verifier_status" "0" "$?"
assert_pass_if_clean "test_record_review_tolerates_verifier_status_field"

# test_mirror_defenses_tolerates_new_fields
# mirror-defenses-to-pr.sh must NOT have a hardcoded field allowlist that would reject verifier fields
echo "--- test_mirror_defenses_tolerates_new_fields ---"
_snapshot_fail
# It should NOT have a strict field allowlist. Check it doesn't have "only allow" or "strict fields" patterns
# that would reject new fields. This test passes when verifier fields are NOT filtered out.
# Check: script must contain no "strict" field restriction excluding verifier_status
! grep -qiE "^\s*(allowed_fields|ALLOWED_FIELDS|strict_fields)\s*=.*\[" "$MIRROR_DEFENSES_SH" 2>/dev/null
assert_eq "test_mirror_defenses_tolerates_new_fields: mirror-defenses.sh has no strict field allowlist" "0" "$?"
assert_pass_if_clean "test_mirror_defenses_tolerates_new_fields"

print_summary
