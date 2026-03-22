---
id: w22-dzuq
status: open
deps: [w22-uyhe, w22-4mgj]
links: []
created: 2026-03-22T20:02:57Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-nv42
---
# Integration test: full pipeline from diff input through classifier to workflow branching

Write integration tests that verify the complete flow from a diff input through the classifier to the REVIEW-WORKFLOW.md branching decisions. These tests run after implementation tasks w22-t2nm and w22-uyhe are complete.

**Scope**: These are written as GREEN tests (not RED-first) because they verify end-to-end behavior of two already-implemented components working together, not individual new behaviors. Integration test task exemption applies: covers the external boundary (classifier process → workflow shell variables) end-to-end.

**Tests to write** in `tests/workflows/test-review-workflow-size-thresholds.sh` (extend the file created in task w22-8g9v):

1. `test_integration_upgrade_path_end_to_end` — pipe a 300-line non-test diff through the classifier, capture `size_action`, then run the Step 3 shell logic and assert `REVIEW_AGENT_OVERRIDE` is set to the opus agent
2. `test_integration_reject_path_end_to_end` — pipe a 600-line diff through the classifier, capture `size_action`, run Step 3 logic, assert rejection message contains "large-diff-splitting-guide.md" and result is "rejected"
3. `test_integration_merge_commit_bypass_end_to_end` — pipe a 600-line diff with `MOCK_MERGE_HEAD=1`, verify classifier returns `is_merge_commit: true`, and Step 3 logic does NOT reject

**Fuzzy match**: Already covered by the `.test-index` entry created in task w22-8g9v for `REVIEW-WORKFLOW.md → test-review-workflow-size-thresholds.sh`.

**Integration test exemption justification**: These tests cross the classifier-process boundary and the REVIEW-WORKFLOW Step 3 shell extraction logic. No suitable mock exists for the classifier process in the context of integration testing. The integration surface (classifier JSON → workflow branch decision) is the primary risk surface for this story.

**TDD Requirement**: Integration test task — these tests are written after implementation tasks are complete (w22-t2nm and w22-uyhe). They are GREEN-first integration tests, not RED-first unit tests. This is the valid integration exemption: "task is written after implementation to verify the boundary interaction end-to-end."

**Files**:
- `tests/workflows/test-review-workflow-size-thresholds.sh` (Edit — add 3 integration test functions and register in runner block)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] All 3 integration test functions exist and pass GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/workflows/test-review-workflow-size-thresholds.sh 2>&1 | grep -c "test_integration_" | awk '{exit ($1 < 3)}'
- [ ] Integration test for upgrade path verifies opus agent assignment
  Verify: grep -q "test_integration_upgrade_path_end_to_end" $(git rev-parse --show-toplevel)/tests/workflows/test-review-workflow-size-thresholds.sh
- [ ] Integration test for rejection path verifies splitting guide reference
  Verify: grep -q "test_integration_reject_path_end_to_end" $(git rev-parse --show-toplevel)/tests/workflows/test-review-workflow-size-thresholds.sh
- [ ] Integration test for merge commit bypass verifies no rejection
  Verify: grep -q "test_integration_merge_commit_bypass_end_to_end" $(git rev-parse --show-toplevel)/tests/workflows/test-review-workflow-size-thresholds.sh
