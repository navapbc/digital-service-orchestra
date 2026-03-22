---
id: dso-4mdr
status: in_progress
deps: [dso-qzn4]
links: []
created: 2026-03-22T15:17:21Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# RED: Write failing integration test for classifier-to-named-agent dispatch pipeline

Write a failing integration test that verifies the end-to-end path: classifier invocation → tier selection → named agent dispatch → schema-valid reviewer-findings.json output.

## TDD Requirement

Write the failing test BEFORE the REVIEW-WORKFLOW.md update (which happens in the next task). Tests must be RED (failing) when this task is complete because the REVIEW-WORKFLOW.md changes haven't been applied yet.

## Test File

Create: tests/hooks/test-review-workflow-classifier-dispatch.sh

Test file basename normalized: 'testreviewworkflowclassifierdispatchsh'
Source basename normalized: 'reviewworkflowmd' (for REVIEW-WORKFLOW.md, not a direct match)
Since the test name does not fuzzy-match 'reviewworkflowmd', add .test-index entry:
  plugins/dso/docs/workflows/REVIEW-WORKFLOW.md: tests/hooks/test-review-workflow-classifier-dispatch.sh

## Test Cases to Write (all RED initially)

### Classifier integration
- test_review_workflow_step3_calls_classifier — verify that after the REVIEW-WORKFLOW.md update, Step 3 produces a tier variable (light|standard|deep) rather than a MODEL variable
- test_classifier_output_parsed_for_tier_selection — verify that selected_tier from classifier JSON is used to route dispatch
- test_classifier_failure_defaults_to_standard_tier — when classifier exits non-zero, verify fallback behavior produces 'standard' tier

### Named agent dispatch
- test_light_tier_dispatches_to_code_reviewer_light — Light tier routes to dso:code-reviewer-light  
- test_standard_tier_dispatches_to_code_reviewer_standard — Standard tier routes to dso:code-reviewer-standard
- test_classifier_json_schema_valid — classifier output matches contract fields from dso-ofdr

## Note on Integration Test Scope

Per the story note: 'Integration test: invoke at least one generated agent with a minimal diff and verify schema-valid output on first attempt. This validates the end-to-end path from classifier → named agent → write-reviewer-findings.sh.'

The full end-to-end test (invoking the actual named agent) requires a running Claude Code environment and is validated manually against the schema compliance baseline from dso-9ltc. This test file covers the classifier parsing + tier selection logic that can be tested without invoking a live sub-agent.

## Implementation Steps

1. Create tests/hooks/test-review-workflow-classifier-dispatch.sh
2. Write all test cases above as bash tests using tests/lib/assert.sh patterns
3. Add .test-index entries:
   - plugins/dso/docs/workflows/REVIEW-WORKFLOW.md: tests/hooks/test-review-workflow-classifier-dispatch.sh
4. Run test file to confirm FAIL output (RED state)

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes overall (exit 0) — but this specific test file FAILS (RED tests present)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/hooks/test-review-workflow-classifier-dispatch.sh" 2>&1 | grep -q 'FAIL'
- [ ] Test file exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] .test-index entry for REVIEW-WORKFLOW.md added
  Verify: grep -q 'REVIEW-WORKFLOW.md' $(git rev-parse --show-toplevel)/.test-index


## Notes

**2026-03-22T16:49:51Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T16:50:21Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T16:51:37Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T16:51:48Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED tests only)

**2026-03-22T16:51:57Z**

CHECKPOINT 5/6: Validation passed ✓ (no Python files to lint)

**2026-03-22T16:52:12Z**

CHECKPOINT 6/6: Done ✓
