---
id: dso-guue
status: closed
deps: []
links: []
created: 2026-03-22T17:44:06Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# RED test: deep tier dispatches 3 parallel sonnet agents with temp findings files

Write failing tests in tests/hooks/test-review-workflow-classifier-dispatch.sh verifying that when the classifier selects 'deep' tier, REVIEW-WORKFLOW.md Step 4 documents dispatching 3 parallel sonnet agents (dso:code-reviewer-deep-correctness, dso:code-reviewer-deep-verification, dso:code-reviewer-deep-hygiene) and saving each result to reviewer-findings-a.json, reviewer-findings-b.json, reviewer-findings-c.json respectively.

TDD REQUIREMENT: Write failing tests FIRST. All tests must be RED before Task 2 is implemented.

Tests to write (add to tests/hooks/test-review-workflow-classifier-dispatch.sh):
- test_deep_tier_documents_three_parallel_sonnet_dispatches: verify REVIEW-WORKFLOW.md contains 'code-reviewer-deep-correctness', 'code-reviewer-deep-verification', 'code-reviewer-deep-hygiene' in Step 4
- test_deep_tier_documents_temp_file_naming: verify REVIEW-WORKFLOW.md references 'reviewer-findings-a.json', 'reviewer-findings-b.json', 'reviewer-findings-c.json' temp file paths in 
- test_deep_tier_documents_orchestrator_copy_step: verify REVIEW-WORKFLOW.md documents copying reviewer-findings.json to temp path after each sonnet agent completes

File: tests/hooks/test-review-workflow-classifier-dispatch.sh
Test names (fuzzy-matchable via 'reviewworkflowclassifierdispatch'):
  - test_deep_tier_documents_three_parallel_sonnet_dispatches
  - test_deep_tier_documents_temp_file_naming
  - test_deep_tier_documents_orchestrator_copy_step

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/hooks/test-review-workflow-classifier-dispatch.sh contains test_deep_tier_documents_three_parallel_sonnet_dispatches
  Verify: grep -q "test_deep_tier_documents_three_parallel_sonnet_dispatches" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] tests/hooks/test-review-workflow-classifier-dispatch.sh contains test_deep_tier_documents_temp_file_naming
  Verify: grep -q "test_deep_tier_documents_temp_file_naming" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] tests/hooks/test-review-workflow-classifier-dispatch.sh contains test_deep_tier_documents_orchestrator_copy_step
  Verify: grep -q "test_deep_tier_documents_orchestrator_copy_step" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] All three new tests FAIL before Task dso-7hj9 is implemented (RED state confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh 2>&1 | grep -E "FAIL|PASS" | grep "test_deep_tier_documents"

## Notes

**2026-03-22T18:21:46Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T18:37:46Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T18:38:45Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T18:38:46Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T18:38:55Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T18:49:55Z**

CHECKPOINT 6/6: Done ✓
