#!/usr/bin/env bash
# tests/scripts/test-review-contract-refs.sh
# Verify that reviewer-base.md and review-fix-dispatch.md both reference
# the canonical contract files review-findings-schema.md and review-defenses.md.
#
# Purpose: prevent silent contract drift — if either workflow prompt stops
# referencing these contracts, this harness catches it immediately.
#
# Tests:
#  1. test_reviewer_base_references_findings_schema
#     — reviewer-base.md contains 'review-findings-schema.md'
#  2. test_reviewer_base_references_defenses
#     — reviewer-base.md contains 'review-defenses.md'
#  3. test_review_fix_dispatch_references_findings_schema
#     — review-fix-dispatch.md contains 'review-findings-schema.md'
#  4. test_review_fix_dispatch_references_defenses
#     — review-fix-dispatch.md contains 'review-defenses.md'
#
# Usage: bash tests/scripts/test-review-contract-refs.sh
# Returns: exit 0 if all checks pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/plugins/dso/docs/workflows/prompts"
REVIEWER_BASE="$PROMPTS_DIR/reviewer-base.md"
REVIEW_FIX_DISPATCH="$PROMPTS_DIR/review-fix-dispatch.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-contract-refs.sh ==="

_assert_file_references() {
    local file="$1" contract="$2" label="$3"
    local _found=0
    grep -qF "$contract" "$file" && _found=1
    assert_eq "$label" "1" "$_found"
}

# ── test_reviewer_base_references_findings_schema ─────────────────────────────
# reviewer-base.md must reference review-findings-schema.md so reviewers
# know the canonical field definitions and relation taxonomy.
test_reviewer_base_references_findings_schema() {
    _snapshot_fail
    _assert_file_references \
        "$REVIEWER_BASE" \
        "review-findings-schema.md" \
        "test_reviewer_base_references_findings_schema: reviewer-base.md references 'review-findings-schema.md'"
    assert_pass_if_clean "test_reviewer_base_references_findings_schema"
}

# ── test_reviewer_base_references_defenses ────────────────────────────────────
# reviewer-base.md must reference review-defenses.md so reviewers
# know the DefenseStore record shape and DEFENSE_RECORD: parsing prefix.
test_reviewer_base_references_defenses() {
    _snapshot_fail
    _assert_file_references \
        "$REVIEWER_BASE" \
        "review-defenses.md" \
        "test_reviewer_base_references_defenses: reviewer-base.md references 'review-defenses.md'"
    assert_pass_if_clean "test_reviewer_base_references_defenses"
}

# ── test_review_fix_dispatch_references_findings_schema ───────────────────────
# review-fix-dispatch.md must reference review-findings-schema.md so the
# fix-dispatch orchestrator correctly interprets cycle-N+1 relation fields.
test_review_fix_dispatch_references_findings_schema() {
    _snapshot_fail
    _assert_file_references \
        "$REVIEW_FIX_DISPATCH" \
        "review-findings-schema.md" \
        "test_review_fix_dispatch_references_findings_schema: review-fix-dispatch.md references 'review-findings-schema.md'"
    assert_pass_if_clean "test_review_fix_dispatch_references_findings_schema"
}

# ── test_review_fix_dispatch_references_defenses ─────────────────────────────
# review-fix-dispatch.md must reference review-defenses.md so the
# fix-dispatch orchestrator understands the DEFENSE_RECORD: parsing prefix
# and cited_lines_fingerprint algorithm.
test_review_fix_dispatch_references_defenses() {
    _snapshot_fail
    _assert_file_references \
        "$REVIEW_FIX_DISPATCH" \
        "review-defenses.md" \
        "test_review_fix_dispatch_references_defenses: review-fix-dispatch.md references 'review-defenses.md'"
    assert_pass_if_clean "test_review_fix_dispatch_references_defenses"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_reviewer_base_references_findings_schema
test_reviewer_base_references_defenses
test_review_fix_dispatch_references_findings_schema
test_review_fix_dispatch_references_defenses

print_summary
