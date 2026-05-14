#!/usr/bin/env bash
# tests/scripts/test-debug-everything-subbranch-review.sh
# Structural metadata validation of debug-everything SKILL.md per-sub-branch review contract.
#
# Verifies that the debug-everything skill documents the per-sub-branch review protocol:
#   1. Schema validation via validate-review-output.sh
#   2. Discriminated review outcomes: MERGED / ESCALATED / ERROR
#   3. Floor-guard of 1 for max_resolution_attempts
#   4. SUBBRANCH_ESCALATED: ticket comment written before PR annotation
#   5. BLOCKED_SUBBRANCHES: PR annotation field
#   6. ESCALATED outcome does NOT halt the tier loop (loop continues)
#
# Test status: All 6 tests are RED — SKILL.md per-sub-branch review section not yet written.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-subbranch-review.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-subbranch-review.sh ==="

test_subbranch_review_invokes_schema_validation() {
    local result="missing"
    if grep -qF 'validate-review-output.sh' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_review_invokes_schema_validation: SKILL.md references validate-review-output.sh in per-sub-branch review context" "found" "$result"
}

test_subbranch_review_discriminated_outcomes() {
    local result="missing"
    # All three discriminated outcome strings must be present for the test to pass
    if grep -qF 'MERGED' "$SKILL_FILE" 2>/dev/null && \
       grep -qF 'ESCALATED' "$SKILL_FILE" 2>/dev/null && \
       grep -qF 'ERROR' "$SKILL_FILE" 2>/dev/null; then
        # Must have the specific per-sub-branch discriminated outcome table/block
        if grep -qE '(MERGED|ESCALATED|ERROR).*sub.branch|sub.branch.*(MERGED|ESCALATED|ERROR)|review.*outcome.*(MERGED|ESCALATED|ERROR)|(MERGED|ESCALATED|ERROR).*review.*outcome' "$SKILL_FILE" 2>/dev/null; then
            result="found"
        fi
    fi
    assert_eq "test_subbranch_review_discriminated_outcomes: SKILL.md documents MERGED/ESCALATED/ERROR as discriminated per-sub-branch review outcomes" "found" "$result"
}

test_subbranch_review_floor_guard() {
    local result="missing"
    if grep -qE 'floor.*max_resolution_attempts|max_resolution_attempts.*floor' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_review_floor_guard: SKILL.md documents floor guard on max_resolution_attempts (minimum 1 attempt)" "found" "$result"
}

test_subbranch_escalation_ordering() {
    local result="missing"
    if grep -qF 'SUBBRANCH_ESCALATED:' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_escalation_ordering: SKILL.md contains SUBBRANCH_ESCALATED: ticket comment written before PR annotation" "found" "$result"
}

test_subbranch_blocked_subbranches_annotation() {
    local result="missing"
    if grep -qF 'BLOCKED_SUBBRANCHES:' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_blocked_subbranches_annotation: SKILL.md contains BLOCKED_SUBBRANCHES: PR annotation field" "found" "$result"
}

test_subbranch_escalation_does_not_halt_loop() {
    local result="missing"
    if grep -qE '(ESCALATED.*continue|continue.*next sub.branch|ESCALATED.*does not halt|loop continues.*ESCALATED|next sub.branch.*after.*ESCALATED)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_escalation_does_not_halt_loop: SKILL.md states ESCALATED outcome does not halt the tier loop (continues to next sub-branch)" "found" "$result"
}

echo ""
echo "--- test_subbranch_review_invokes_schema_validation ---"
test_subbranch_review_invokes_schema_validation
echo ""
echo "--- test_subbranch_review_discriminated_outcomes ---"
test_subbranch_review_discriminated_outcomes
echo ""
echo "--- test_subbranch_review_floor_guard ---"
test_subbranch_review_floor_guard
echo ""
echo "--- test_subbranch_escalation_ordering ---"
test_subbranch_escalation_ordering
echo ""
echo "--- test_subbranch_blocked_subbranches_annotation ---"
test_subbranch_blocked_subbranches_annotation
echo ""
echo "--- test_subbranch_escalation_does_not_halt_loop ---"
test_subbranch_escalation_does_not_halt_loop
echo ""
print_summary
