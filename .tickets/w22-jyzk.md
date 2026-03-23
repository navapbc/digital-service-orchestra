---
id: w22-jyzk
status: open
deps: [w22-r2eh, w22-1d6q, w22-hwmo, w22-tmkk, w22-ebri]
links: []
created: 2026-03-22T17:46:20Z
type: task
parent: w21-nv42  # As a DSO practitioner, oversized diffs are rejected with actionable guidance
priority: 2
assignee: Joe Oakhart
---
# Update .test-index and validate test gate associations for w21-nv42

Update .test-index at repo root to ensure all source files modified in w21-nv42 have correct test associations, and verify the test gate will pass.

Unit Test Exemption Justification:
(1) No conditional logic — this is structural file mapping.
(2) Any test would only check file content (change-detector), not behavioral correctness.
(3) Infrastructure-boundary-only — test gate configuration, no business logic.

Changes required:

1. Add RED marker for classifier to .test-index:
   EXISTING entry: (check if plugins/dso/scripts/review-complexity-classifier.sh is in .test-index)
   If not present, add:
     plugins/dso/scripts/review-complexity-classifier.sh: tests/hooks/test-review-complexity-classifier.sh [test_300_line_diff_triggers_model_upgrade]
   After T2 passes all tests: remove the [marker] from the entry.

2. Update REVIEW-WORKFLOW.md test-index entry:
   EXISTING entry: plugins/dso/docs/workflows/REVIEW-WORKFLOW.md: tests/workflows/test-review-workflow-no-snapshot.sh
   Add test-review-workflow-classifier-dispatch.sh to the entry:
     plugins/dso/docs/workflows/REVIEW-WORKFLOW.md: tests/workflows/test-review-workflow-no-snapshot.sh, tests/hooks/test-review-workflow-classifier-dispatch.sh [test_workflow_step3_checks_size_rejection_field]
   After T4 passes all tests: remove the [marker].

3. Add large-diff-splitting-guide.md to .test-index if any test references it:
   After T3 creates test_workflow_references_splitting_guide_file:
     plugins/dso/docs/prompts/large-diff-splitting-guide.md: tests/hooks/test-review-workflow-classifier-dispatch.sh
   (No RED marker needed since T5 creates the file independently)

4. Run validate-issues.sh to confirm no health issues:
   $(git rev-parse --show-toplevel)/scripts/validate-issues.sh

Files modified:
- .test-index (repo root)


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] .test-index contains entry for review-complexity-classifier.sh with tests/hooks/test-review-complexity-classifier.sh
  Verify: grep -q 'review-complexity-classifier.sh.*test-review-complexity-classifier' $(git rev-parse --show-toplevel)/.test-index
- [ ] .test-index entry for REVIEW-WORKFLOW.md includes test-review-workflow-classifier-dispatch.sh
  Verify: grep 'REVIEW-WORKFLOW.md' $(git rev-parse --show-toplevel)/.test-index | grep -q 'test-review-workflow-classifier-dispatch'
- [ ] No RED markers remain in .test-index for w21-nv42 tasks (all removed after GREEN)
  Verify: grep -E 'review-complexity-classifier|REVIEW-WORKFLOW' $(git rev-parse --show-toplevel)/.test-index | grep -v '\[test_'
- [ ] validate-issues.sh passes (exit 0)
  Verify: $(git rev-parse --show-toplevel)/scripts/validate-issues.sh
