---
id: w21-npxr
status: closed
deps: [w21-9cvk]
links: []
created: 2026-03-20T01:05:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# GREEN: Add post-investigation complexity evaluation + sub-agent detection to fix-bug


## Notes

**2026-03-20T01:06:16Z**

## Description
Edit plugins/dso/skills/fix-bug/SKILL.md:
1. Add Step 4.5: Fix Complexity Evaluation between Fix Approval (Step 4) and RED Test (Step 5) — invoke shared complexity evaluator on proposed fix scope; TRIVIAL/MODERATE proceed to Step 5; COMPLEX creates epic via /dso:brainstorm and stops
2. Add Sub-Agent Context Detection section — primary: orchestrator sets 'You are running as a sub-agent' in dispatch prompt; fallback: check Agent tool availability before dispatching ADVANCED/ESCALATED sub-agents
3. Add Escalation Report Format — structured result with fields: escalation_type, bug_id, investigation_tier_needed, investigation_findings, escalation_reason

TDD: Task w21-9cvk RED tests turn GREEN after this implementation.

## File Impact
- plugins/dso/skills/fix-bug/SKILL.md (modify — add Step 4.5, sub-agent detection, escalation report)

## ACCEPTANCE CRITERIA
- [ ] fix-bug SKILL.md contains 'Step 4.5' heading AND 'complexity-evaluator' reference
  Verify: grep -q 'Step 4.5' plugins/dso/skills/fix-bug/SKILL.md && grep -q 'complexity-evaluator' plugins/dso/skills/fix-bug/SKILL.md
- [ ] fix-bug SKILL.md contains 'Escalation Report' section AND field names 'bug_id', 'investigation_findings'
  Verify: grep -q 'Escalation Report' plugins/dso/skills/fix-bug/SKILL.md && grep -q 'bug_id' plugins/dso/skills/fix-bug/SKILL.md && grep -q 'investigation_findings' plugins/dso/skills/fix-bug/SKILL.md
- [ ] fix-bug SKILL.md contains 'running as a sub-agent' AND 'Agent tool'
  Verify: grep -q 'running as a sub-agent' plugins/dso/skills/fix-bug/SKILL.md && grep -q 'Agent tool' plugins/dso/skills/fix-bug/SKILL.md
- [ ] RED tests from w21-9cvk now pass (GREEN)
  Verify: bash tests/hooks/test-fix-bug-skill.sh 2>&1 | tail -1 | grep -q 'FAILED: 0'

**2026-03-20T01:31:58Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T01:32:19Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T01:32:24Z**

CHECKPOINT 3/6: Tests written (pre-existing RED tests) ✓

**2026-03-20T01:32:58Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T01:33:08Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T01:33:31Z**

CHECKPOINT 6/6: Done ✓
