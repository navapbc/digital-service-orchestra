---
id: dso-5uik
status: open
deps: [dso-gego]
links: []
created: 2026-03-22T17:44:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# RED test: resolution sub-agent isolation — receives findings via prompt path, not direct file access

Write failing tests verifying that for deep tier, the resolution sub-agent is documented to receive reviewer-findings.json via the authoritative file path (written by opus), not the temp a/b/c files directly. This ensures the single-writer invariant and correct file-overlap validation in record-review.sh.

TDD REQUIREMENT: Tests must be RED before Task 6 is implemented.

Tests to add to tests/hooks/test-review-workflow-classifier-dispatch.sh:
- test_deep_tier_resolution_uses_authoritative_findings: verify REVIEW-WORKFLOW.md Autonomous Resolution Loop documents passing the opus-written reviewer-findings.json path (not temp paths a/b/c) to the resolution sub-agent
- test_deep_tier_resolution_cached_model_is_opus: verify REVIEW-WORKFLOW.md documents that {cached_model} for deep tier is 'opus' (matches review-fix-dispatch.md Step 4 validation using opus)

File: tests/hooks/test-review-workflow-classifier-dispatch.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_deep_tier_resolution_uses_authoritative_findings exists and is RED before dso-xx59
  Verify: grep -q "test_deep_tier_resolution_uses_authoritative_findings" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] test_deep_tier_resolution_cached_model_is_opus exists and is RED before dso-xx59
  Verify: grep -q "test_deep_tier_resolution_cached_model_is_opus" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh

## Notes

**2026-03-22T19:17:34Z**

CHECKPOINT 0/6: SESSION_END — Not started. Resume with /dso:sprint w21-ykic --resume
