---
id: dso-xx59
status: open
deps: [dso-5uik]
links: []
created: 2026-03-22T17:45:05Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# Document resolution sub-agent isolation for deep tier in REVIEW-WORKFLOW.md

Update REVIEW-WORKFLOW.md Autonomous Resolution Loop section to document deep-tier-specific behavior: the resolution sub-agent receives findings via the authoritative reviewer-findings.json path (written by the opus agent), not the sonnet temp files.

TDD REQUIREMENT: Tests from dso-5uik must be RED before this task is implemented.

Implementation in plugins/dso/docs/workflows/REVIEW-WORKFLOW.md, Autonomous Resolution Loop section:
1. Add a note under the 'Dispatch' paragraph that for deep tier:
   - {cached_model} = 'opus' (matching deep tier model)
   - {findings_file} = the authoritative $ARTIFACTS_DIR/reviewer-findings.json (written by dso:code-reviewer-deep-arch)
   - The resolution sub-agent MUST NOT read or write reviewer-findings-{a,b,c}.json — those are sonnet-only artifacts consumed only during the opus synthesis pass
2. Confirm the existing ISOLATION PROHIBITION note (no worktree isolation) applies to deep tier resolution as well

File impact:
- Edit: plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Tests from dso-5uik now PASS (GREEN state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh 2>&1 | grep "test_deep_tier_resolution_uses_authoritative_findings" | grep -q "PASS"
- [ ] REVIEW-WORKFLOW.md Autonomous Resolution Loop documents deep tier cached_model = 'opus'
  Verify: grep -A20 "Autonomous Resolution Loop" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md | grep -q "opus"
- [ ] REVIEW-WORKFLOW.md documents resolution sub-agent must not access reviewer-findings-{a,b,c}.json
  Verify: grep -q "reviewer-findings-{a,b,c}" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

## Notes

**2026-03-22T19:17:34Z**

CHECKPOINT 0/6: SESSION_END — Not started. Resume with /dso:sprint w21-ykic --resume
