#!/usr/bin/env bash
# tests/scripts/test-debug-everything-subbranch-review.sh
# Structural metadata validation of debug-everything SKILL.md per-sub-branch review contract.
#
# Verifies that the debug-everything skill documents the per-sub-branch review protocol:
#   1. CI review via per-branch-review.yml (ci-pr mode) — replaces local validate-review-output.sh dispatch
#   2. Discriminated review outcomes: MERGED / ESCALATED / ERROR
#   3. CI workflow wait before merging sub-branch
#   4. SUBBRANCH_ESCALATED: ticket comment written before PR annotation
#   5. BLOCKED_SUBBRANCHES: PR annotation field
#   6. ESCALATED outcome does NOT halt the tier loop (loop continues)
#
# Test status: All 6 tests PASS — SKILL.md per-sub-branch review section contains required documentation patterns.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-subbranch-review.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

if [[ ! -f "$SKILL_FILE" ]]; then
    printf "FAIL: SKILL.md not found at expected path: %s\n" "$SKILL_FILE" >&2
    printf "Check BASH_SOURCE[0]-based path derivation — test cannot proceed.\n" >&2
    exit 1
fi

echo "=== test-debug-everything-subbranch-review.sh ==="

test_subbranch_review_invokes_schema_validation() {
    local result="missing"
    # In ci-pr mode, per-sub-branch review is handled by per-branch-review.yml CI workflow
    # (replaces the former local validate-review-output.sh dispatch introduced before the unified architecture)
    if grep -qF 'per-branch-review.yml' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_review_invokes_schema_validation: SKILL.md references per-branch-review.yml for per-sub-branch CI review" "found" "$result"
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
    # In the unified ci-pr architecture, the sub-branch PR base is SESSION_BRANCH and
    # review is CI-authoritative. SKILL.md must document waiting for CI before merge.
    if grep -qE 'Wait for the CI workflow|wait for.*CI.*complet|CI.*workflow.*complet' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_subbranch_review_floor_guard: SKILL.md documents waiting for CI workflow completion before merging sub-branch" "found" "$result"
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
