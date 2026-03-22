---
id: dso-jzpv
status: open
deps: [dso-7hj9, dso-gego, dso-xx59]
links: []
created: 2026-03-22T17:45:19Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# Integration test: deep tier sonnet-to-opus handoff — opus output passes record-review.sh validation

Write an integration test that verifies the end-to-end deep tier handoff: when 3 sonnet temp findings files exist in ARTIFACTS_DIR, the opus dispatch prompt correctly injects the findings inline (matching the format expected by code-reviewer-deep-arch.md), and that opus output schema (hygiene, design, maintainability, correctness, verification dimensions) passes write-reviewer-findings.sh and record-review.sh validation.

Integration test approach (bash test, no live sub-agents):
- Create fixture: 3 minimal valid reviewer-findings-{a,b,c}.json in a temp ARTIFACTS_DIR with valid schemas (using validate-review-output.sh code-review-dispatch to confirm)
- Verify: python3 extraction of 'findings' arrays from each temp file succeeds
- Verify: combined inline findings block matches the expected format (=== SONNET-A FINDINGS === header)
- Verify: a synthetic opus-like reviewer-findings.json (merged from all 3) passes write-reviewer-findings.sh validation
- Verify: record-review.sh accepts a valid diff hash + reviewer hash pair

File: tests/hooks/test-review-workflow-classifier-dispatch.sh
Test name: test_deep_tier_sonnet_to_opus_handoff_schema_passes_validation
(normalized: 'reviewworkflowclassifierdispatch' substring match — fuzzy-matchable)

This is an integration test task (crosses file system boundary). Does not require a RED test dependency — it is written after the implementation tasks. No exemption needed: the test environment has the artifact scripts available.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] test_deep_tier_sonnet_to_opus_handoff_schema_passes_validation exists in test file
  Verify: grep -q "test_deep_tier_sonnet_to_opus_handoff_schema_passes_validation" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] Integration test creates 3 fixture reviewer-findings-{a,b,c}.json and validates schemas pass validate-review-output.sh
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh 2>&1 | grep "test_deep_tier_sonnet_to_opus_handoff_schema_passes_validation" | grep -q "PASS"
- [ ] Integration test verifies write-reviewer-findings.sh accepts merged opus-style findings
  Verify: grep -q "write-reviewer-findings" $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh

## Notes

**2026-03-22T19:17:34Z**

CHECKPOINT 0/6: SESSION_END — Not started. Resume with /dso:sprint w21-ykic --resume
