---
id: w21-kp0l
status: closed
deps: [w21-tcti]
links: []
created: 2026-03-20T02:38:59Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-mzof
---
# GREEN: Add contract detection pass to implementation-plan SKILL.md

## Description
Edit plugins/dso/skills/implementation-plan/SKILL.md. Insert a '### Contract Detection Pass' subsection in Step 3, after the 'Documentation Updates' subsection and before the '---' separator for Step 4. Contents:

1. When to run: After file impact analysis in Step 3, before finalizing the task list
2. V1 detection heuristic — two patterns:
   (a) Signal emit/parse pairs: file impact includes a component producing structured output (STATUS:, RESULT:, REPORT: markers) AND another parsing it
   (b) Orchestrator/sub-agent report schemas: file impact includes a skill dispatching sub-agents AND defining expected return format
3. Contract artifact: Create under plugins/dso/docs/contracts/<interface-name>.md with sections: Signal Name, Emitter, Parser, Fields, Example
4. Cross-story deduplication: Before creating contract task, run tk dep tree <parent-epic-id>, check if existing task title contains 'Contract:' and same interface name. If found, wire as dependent. If not, create.
5. Contract task as first dependency: blocks all implementation tasks touching either side of the interface

TDD: Task w21-tcti RED tests turn GREEN after this implementation.

## File Impact
- plugins/dso/skills/implementation-plan/SKILL.md (modify — add Contract Detection Pass section)

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash tests/run-all.sh
- [ ] SKILL.md contains contract detection heading
  Verify: grep -q '### Contract Detection Pass' plugins/dso/skills/implementation-plan/SKILL.md
- [ ] Contains emit/parse pattern description
  Verify: grep -q 'emit' plugins/dso/skills/implementation-plan/SKILL.md && grep -q 'parse' plugins/dso/skills/implementation-plan/SKILL.md
- [ ] Contains orchestrator/sub-agent pattern
  Verify: grep -qE '(orchestrator.*sub-agent|sub-agent.*orchestrator)' plugins/dso/skills/implementation-plan/SKILL.md
- [ ] Contains deduplication via tk dep tree
  Verify: grep -q 'tk dep tree' plugins/dso/skills/implementation-plan/SKILL.md && grep -qE '(existing contract|Contract:)' plugins/dso/skills/implementation-plan/SKILL.md
- [ ] Contains artifact path
  Verify: grep -q 'plugins/dso/docs/contracts/' plugins/dso/skills/implementation-plan/SKILL.md
- [ ] All 5 RED tests pass (GREEN)
  Verify: bash tests/scripts/test-implementation-plan-contracts.sh 2>&1 | grep -q 'RESULT: PASS'
- [ ] All 5 individually pass
  Verify: test $(bash tests/scripts/test-implementation-plan-contracts.sh 2>&1 | grep -c 'PASS:') -ge 5


## Notes

**2026-03-20T03:26:03Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T03:26:16Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T03:26:22Z**

CHECKPOINT 3/6: Tests written (none required — RED tests exist) ✓

**2026-03-20T03:26:53Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T03:33:30Z**

CHECKPOINT 5/6: Validation passed — all 5 contract tests GREEN (PASSED: 7 FAILED: 0), skill-refs check clean ✓

**2026-03-20T03:33:37Z**

CHECKPOINT 6/6: Done ✓

**2026-03-20T03:36:55Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/skills/implementation-plan/SKILL.md. Tests: all 7 assertions pass (5 tests GREEN). Review: passed (score 4/5).
