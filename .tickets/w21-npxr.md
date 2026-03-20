---
id: w21-npxr
status: open
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
