#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

test_review_workflow_has_huge_divert_step() {
    _snapshot_fail
    local wf_file="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

    # Check reference to review-huge-diff-check.sh exists
    local has_check_script
    grep -q 'review-huge-diff-check\.sh' "$wf_file" 2>/dev/null \
        && has_check_script="present" || has_check_script="absent"
    assert_eq "test_review_workflow_has_huge_divert_step_check_script" "present" "$has_check_script"

    # Check reference to REVIEW-WORKFLOW-HUGE.md exists
    local has_huge_workflow
    grep -q 'REVIEW-WORKFLOW-HUGE\.md' "$wf_file" 2>/dev/null \
        && has_huge_workflow="present" || has_huge_workflow="absent"
    assert_eq "test_review_workflow_has_huge_divert_step_huge_workflow" "present" "$has_huge_workflow"

    # Check both strings appear after "## Step 2" section
    local step2_line; step2_line=$(grep -n '## Step 2' "$wf_file" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
    local check_line; check_line=$(grep -n 'review-huge-diff-check\.sh' "$wf_file" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
    local huge_line; huge_line=$(grep -n 'REVIEW-WORKFLOW-HUGE\.md' "$wf_file" 2>/dev/null | head -1 | cut -d: -f1 || echo "0")
    local position_ok="true"
    [ "$check_line" -gt "$step2_line" ] 2>/dev/null || position_ok="false"
    [ "$huge_line" -gt "$step2_line" ] 2>/dev/null || position_ok="false"
    assert_eq "test_review_workflow_has_huge_divert_step_after_step2" "true" "$position_ok"

    assert_pass_if_clean "test_review_workflow_has_huge_divert_step"
}

test_review_workflow_has_huge_divert_step
print_summary
