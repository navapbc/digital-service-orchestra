#!/usr/bin/env bash
# tests/workflows/test-review-workflow-severity-schema.sh
#
# Structural contract tests (design-contract exceptions per behavioral-testing-standard.md
# Rule 5): REVIEW-WORKFLOW.md and sprint SKILL.md must use severity-based pass/fail language
# instead of score-based thresholds. The workflow text IS the behavioral contract.
#
# RED: tests fail until REVIEW-WORKFLOW.md and sprint SKILL.md are updated.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

# test_review_workflow_no_min_score_passfail_criterion
echo "=== test_review_workflow_no_min_score_passfail_criterion ==="
if ! grep -q 'MIN_SCORE' "$REVIEW_WORKFLOW"; then
    assert_eq "REVIEW-WORKFLOW.md has no MIN_SCORE pass/fail criterion" "absent" "absent"
else
    assert_eq "REVIEW-WORKFLOW.md has no MIN_SCORE pass/fail criterion" \
        "MIN_SCORE absent (severity-based pass/fail)" \
        "MIN_SCORE still present in REVIEW-WORKFLOW.md"
fi

# test_review_workflow_no_all_scores_criterion
echo "=== test_review_workflow_no_all_scores_criterion ==="
if ! grep -q 'all scores >= 4' "$REVIEW_WORKFLOW"; then
    assert_eq "REVIEW-WORKFLOW.md has no 'all scores >= 4' criterion" "absent" "absent"
else
    assert_eq "REVIEW-WORKFLOW.md has no 'all scores >= 4' criterion" \
        "'all scores >= 4' absent (use severity-based criterion)" \
        "'all scores >= 4' still present in REVIEW-WORKFLOW.md"
fi

# test_sprint_skill_no_all_scores_criterion
echo "=== test_sprint_skill_no_all_scores_criterion ==="
if ! grep -q 'all scores >= 4' "$SPRINT_SKILL"; then
    assert_eq "sprint SKILL.md has no 'all scores >= 4' criterion" "absent" "absent"
else
    assert_eq "sprint SKILL.md has no 'all scores >= 4' criterion" \
        "'all scores >= 4' absent (use severity-based criterion)" \
        "'all scores >= 4' still present in sprint SKILL.md"
fi

print_summary
