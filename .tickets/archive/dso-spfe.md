---
id: dso-spfe
status: closed
deps: [dso-7hj9]
links: []
created: 2026-03-22T17:44:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# RED test: opus arch reviewer receives all 3 sonnet findings inline and writes authoritative reviewer-findings.json

Write failing tests verifying the opus architectural reviewer dispatch step documents injecting all 3 sonnet findings inline into the prompt and writing the final authoritative reviewer-findings.json.

TDD REQUIREMENT: Tests must be RED before Task 4 is implemented.

Tests to add to tests/hooks/test-review-workflow-classifier-dispatch.sh:
- test_deep_arch_reviewer_dispatched_after_sonnets: verify REVIEW-WORKFLOW.md documents dispatching dso:code-reviewer-deep-arch after the 3 sonnet agents complete
- test_deep_arch_prompt_includes_inline_findings: verify REVIEW-WORKFLOW.md documents injecting SONNET-A FINDINGS, SONNET-B FINDINGS, SONNET-C FINDINGS into the opus dispatch prompt (matching the input format expected by code-reviewer-deep-arch.md)
- test_deep_arch_writes_authoritative_findings: verify REVIEW-WORKFLOW.md documents that dso:code-reviewer-deep-arch is the sole writer of the final reviewer-findings.json in deep tier (not any of the sonnet agents)
- test_deep_tier_single_writer_invariant: verify REVIEW-WORKFLOW.md does not document sonnet agents writing to the final reviewer-findings.json path (only to temp a/b/c paths)

File: tests/hooks/test-review-workflow-classifier-dispatch.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_deep_arch_reviewer_dispatched_after_sonnets exists and is RED before dso-gego
  Verify: grep -q "test_deep_arch_reviewer_dispatched_after_sonnets" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] test_deep_arch_prompt_includes_inline_findings exists and is RED before dso-gego
  Verify: grep -q "test_deep_arch_prompt_includes_inline_findings" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] test_deep_arch_writes_authoritative_findings exists and is RED before dso-gego
  Verify: grep -q "test_deep_arch_writes_authoritative_findings" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] test_deep_tier_single_writer_invariant exists and is RED before dso-gego
  Verify: grep -q "test_deep_tier_single_writer_invariant" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh

## Notes

**2026-03-22T19:06:09Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T19:06:50Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T19:07:29Z**

CHECKPOINT 3/6: RED tests written — 4 new tests all failing as expected ✓

**2026-03-22T19:07:48Z**

CHECKPOINT 4/6: .test-index RED markers added ✓

**2026-03-22T19:14:48Z**

CHECKPOINT 5/6: Format/lint check — no Python files modified; bash tests confirmed RED as expected ✓

**2026-03-22T19:15:10Z**

CHECKPOINT 6/6: Self-check — all 4 test functions exist, all RED, .test-index RED markers in place ✓
