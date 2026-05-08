#!/usr/bin/env bash
# tests/workflows/test-review-workflow-severity-schema.sh
#
# Structural contract tests (design-contract exceptions per behavioral-testing-standard.md
# Rule 5): REVIEW-WORKFLOW.md and sprint SKILL.md must use severity-based pass/fail language
# instead of score-based thresholds. The workflow text IS the behavioral contract.
#
# Two-part assertions per test:
#   1. Positive: severity-based schema IS documented (what replaced the old schema).
#   2. Negative: legacy score-based schema is NOT present (lock-out post epic 4b8f-924d).
# Pairing the two ensures tests catch both regressions: re-introduction of old schema
# AND accidental removal of the new schema during prose restructuring.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

# ---------------------------------------------------------------------------
# test_review_workflow_severity_pass_fail_criterion
# Positive: REVIEW-WORKFLOW.md documents severity-based pass/fail via findings[].severity
# verify REQUIRED contract elements (severity schema terms) exist in instruction files.
# Removing these terms would break the downstream LLM agent contract. This is structural
# boundary testing, not arbitrary prose pinning.
# ---------------------------------------------------------------------------
echo "=== test_review_workflow_severity_pass_fail_criterion ==="
if grep -q 'findings\[\].severity' "$REVIEW_WORKFLOW"; then
    assert_eq "REVIEW-WORKFLOW.md uses findings[].severity for pass/fail" "present" "present"
else
    assert_eq "REVIEW-WORKFLOW.md uses findings[].severity for pass/fail" \
        "findings[].severity present (severity-based pass/fail)" \
        "findings[].severity missing from REVIEW-WORKFLOW.md"
fi

# ---------------------------------------------------------------------------
# test_review_workflow_no_min_score_passfail_criterion
# Negative: REVIEW-WORKFLOW.md must NOT use MIN_SCORE (legacy score-based schema,
# removed in epic 4b8f-924d; severity-based schema documented above is the replacement).
# instruction-file tests MUST test structural boundaries via grep. These negative
# assertions lock out deprecated severity fields from the review workflow contract.
# Behavioral correctness testing is non-deterministic for LLM instruction files and
# therefore not required per Rule 5.
# ---------------------------------------------------------------------------
echo "=== test_review_workflow_no_min_score_passfail_criterion ==="
if ! grep -q 'MIN_SCORE' "$REVIEW_WORKFLOW"; then
    assert_eq "REVIEW-WORKFLOW.md has no MIN_SCORE pass/fail criterion" "absent" "absent"
else
    assert_eq "REVIEW-WORKFLOW.md has no MIN_SCORE pass/fail criterion" \
        "MIN_SCORE absent (severity-based pass/fail)" \
        "MIN_SCORE still present in REVIEW-WORKFLOW.md"
fi

# ---------------------------------------------------------------------------
# test_review_workflow_severity_trigger_language
# Positive: REVIEW-WORKFLOW.md documents that critical/important findings trigger resolution.
# verify REQUIRED contract elements (severity schema terms) exist in instruction files.
# Removing these terms would break the downstream LLM agent contract. This is structural
# boundary testing, not arbitrary prose pinning.
# ---------------------------------------------------------------------------
echo "=== test_review_workflow_severity_trigger_language ==="
if grep -q 'critical or important finding' "$REVIEW_WORKFLOW"; then
    assert_eq "REVIEW-WORKFLOW.md documents critical/important finding trigger" "present" "present"
else
    assert_eq "REVIEW-WORKFLOW.md documents critical/important finding trigger" \
        "critical/important trigger language present" \
        "critical/important trigger language missing from REVIEW-WORKFLOW.md"
fi

# ---------------------------------------------------------------------------
# test_review_workflow_no_all_scores_criterion
# Negative: REVIEW-WORKFLOW.md must NOT use 'all scores >= 4' (legacy schema,
# removed in epic 4b8f-924d; critical/important severity trigger is the replacement).
# instruction-file tests MUST test structural boundaries via grep. These negative
# assertions lock out deprecated severity fields from the review workflow contract.
# Behavioral correctness testing is non-deterministic for LLM instruction files and
# therefore not required per Rule 5.
# ---------------------------------------------------------------------------
echo "=== test_review_workflow_no_all_scores_criterion ==="
if ! grep -q 'all scores >= 4' "$REVIEW_WORKFLOW"; then
    assert_eq "REVIEW-WORKFLOW.md has no 'all scores >= 4' criterion" "absent" "absent"
else
    assert_eq "REVIEW-WORKFLOW.md has no 'all scores >= 4' criterion" \
        "'all scores >= 4' absent (use severity-based criterion)" \
        "'all scores >= 4' still present in REVIEW-WORKFLOW.md"
fi

# ---------------------------------------------------------------------------
# test_sprint_skill_severity_pass_criterion
# Positive: sprint SKILL.md documents severity-based pass language (no critical/important findings).
# verify REQUIRED contract elements (severity schema terms) exist in instruction files.
# Removing these terms would break the downstream LLM agent contract. This is structural
# boundary testing, not arbitrary prose pinning.
# ---------------------------------------------------------------------------
echo "=== test_sprint_skill_severity_pass_criterion ==="
if grep -q 'critical/important' "$SPRINT_SKILL"; then
    assert_eq "sprint SKILL.md uses critical/important severity language" "present" "present"
else
    assert_eq "sprint SKILL.md uses critical/important severity language" \
        "critical/important severity language present" \
        "critical/important severity language missing from sprint SKILL.md"
fi

# ---------------------------------------------------------------------------
# test_sprint_skill_no_all_scores_criterion
# Negative: sprint SKILL.md must NOT use 'all scores >= 4' (legacy schema,
# removed in epic 4b8f-924d; critical/important severity language is the replacement).
# instruction-file tests MUST test structural boundaries via grep. These negative
# assertions lock out deprecated severity fields from the review workflow contract.
# Behavioral correctness testing is non-deterministic for LLM instruction files and
# therefore not required per Rule 5.
# ---------------------------------------------------------------------------
echo "=== test_sprint_skill_no_all_scores_criterion ==="
if ! grep -q 'all scores >= 4' "$SPRINT_SKILL"; then
    assert_eq "sprint SKILL.md has no 'all scores >= 4' criterion" "absent" "absent"
else
    assert_eq "sprint SKILL.md has no 'all scores >= 4' criterion" \
        "'all scores >= 4' absent (use severity-based criterion)" \
        "'all scores >= 4' still present in sprint SKILL.md"
fi

print_summary
