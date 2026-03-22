---
id: w22-hwmo
status: open
deps: []
links: []
created: 2026-03-22T17:45:29Z
type: task
parent: w21-nv42  # As a DSO practitioner, oversized diffs are rejected with actionable guidance
priority: 2
assignee: Joe Oakhart
---
# Write RED tests for REVIEW-WORKFLOW.md Step 3 size rejection and model upgrade handling

Write failing tests in tests/hooks/test-review-workflow-classifier-dispatch.sh for the workflow-level diff-size handling that will be added in T4.

TDD Requirement: Tests must FAIL before T4 (workflow implementation) and PASS after. Tests verify that REVIEW-WORKFLOW.md Step 3 correctly handles the new classifier output fields.

Tests to add (append to end of tests/hooks/test-review-workflow-classifier-dispatch.sh):

1. test_workflow_step3_checks_size_rejection_field:
   - Grep REVIEW-WORKFLOW.md for 'size_rejection' — should be present (will fail until T4)
   - Assert workflow references the size_rejection field from classifier output

2. test_workflow_step3_checks_model_override_field:
   - Grep REVIEW-WORKFLOW.md for 'model_override' — should be present
   - Assert workflow references model_override to override named agent model

3. test_workflow_step3_rejection_only_on_initial_dispatch:
   - Grep REVIEW-WORKFLOW.md for language clarifying size rejection is skipped during re-review
   - Assert the re-review section (Autonomous Resolution Loop) does NOT apply size rejection

4. test_workflow_step3_rejection_message_references_guide:
   - Grep REVIEW-WORKFLOW.md for 'large-diff-splitting-guide' reference in rejection message template
   - Assert the rejection message includes the guide path

5. test_workflow_references_splitting_guide_file:
   - Assert plugins/dso/docs/prompts/large-diff-splitting-guide.md exists
   - (Will fail until T5 creates the file)

File: tests/hooks/test-review-workflow-classifier-dispatch.sh (append to existing file).

Fuzzy-match check: source 'reviewworkflowmd' normalized. Test file normalized 'testreviewworkflowclassifierdispatchsh' — does NOT contain 'reviewworkflowmd'. .test-index entry required for REVIEW-WORKFLOW.md → this test file. Will be added in T6.


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0) after T4 implementation
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/hooks/test-review-workflow-classifier-dispatch.sh contains test_workflow_step3_checks_size_rejection_field
  Verify: grep -q 'test_workflow_step3_checks_size_rejection_field' $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] tests/hooks/test-review-workflow-classifier-dispatch.sh contains test_workflow_step3_checks_model_override_field
  Verify: grep -q 'test_workflow_step3_checks_model_override_field' $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] tests/hooks/test-review-workflow-classifier-dispatch.sh contains test_workflow_step3_rejection_only_on_initial_dispatch
  Verify: grep -q 'test_workflow_step3_rejection_only_on_initial_dispatch' $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] Tests are RED before T4: bash tests/hooks/test-review-workflow-classifier-dispatch.sh exits non-zero
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh; [ $? -ne 0 ]
- [ ] .test-index entry for REVIEW-WORKFLOW.md includes RED marker and test-review-workflow-classifier-dispatch.sh
  Verify: grep -q 'REVIEW-WORKFLOW.md.*test-review-workflow-classifier-dispatch' $(git rev-parse --show-toplevel)/.test-index
