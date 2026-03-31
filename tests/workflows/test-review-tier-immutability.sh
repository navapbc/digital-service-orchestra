#!/usr/bin/env bash
# tests/workflows/test-review-tier-immutability.sh
# Bugs 7c4a-f465, b9a1-95d8: Verify REVIEW-WORKFLOW.md contains
# an explicit TIER IMMUTABILITY directive prohibiting tier downgrades.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_WF="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-tier-immutability.sh ==="
echo ""

test_tier_immutability_directive_exists() {
    _snapshot_fail
    if [[ ! -f "$REVIEW_WF" ]]; then
        (( ++FAIL ))
        printf "FAIL: REVIEW-WORKFLOW.md not found\n" >&2
        assert_pass_if_clean "test_tier_immutability_directive_exists"
        return
    fi
    local _has_immutability=0
    if grep -qi 'TIER IMMUTABILITY' "$REVIEW_WF" 2>/dev/null; then
        _has_immutability=1
    fi
    assert_eq "REVIEW-WORKFLOW.md contains TIER IMMUTABILITY directive" "1" "$_has_immutability"
    assert_pass_if_clean "test_tier_immutability_directive_exists"
}

test_tier_immutability_prohibits_downgrade() {
    _snapshot_fail
    if [[ ! -f "$REVIEW_WF" ]]; then
        (( ++FAIL ))
        printf "FAIL: REVIEW-WORKFLOW.md not found\n" >&2
        assert_pass_if_clean "test_tier_immutability_prohibits_downgrade"
        return
    fi
    local _section
    _section=$(sed -n '/TIER IMMUTABILITY/,/^$/p' "$REVIEW_WF" 2>/dev/null)
    local _prohibits=0
    if echo "$_section" | grep -qiE '(never|must not|prohibit).*(downgrad|lighter tier|standard.*light|deep.*standard)'; then
        _prohibits=1
    fi
    assert_eq "TIER IMMUTABILITY directive prohibits tier downgrades" "1" "$_prohibits"
    assert_pass_if_clean "test_tier_immutability_prohibits_downgrade"
}

echo "--- test_tier_immutability_directive_exists ---"
test_tier_immutability_directive_exists
echo ""

echo "--- test_tier_immutability_prohibits_downgrade ---"
test_tier_immutability_prohibits_downgrade
echo ""

print_summary
