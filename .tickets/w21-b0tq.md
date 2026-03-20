---
id: w21-b0tq
status: open
deps: [w21-gljg]
links: []
created: 2026-03-20T01:05:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# GREEN: Remove Phase 2.5 from debug-everything + add escalation handling


## Notes

**2026-03-20T01:06:24Z**

## Description
Edit plugins/dso/skills/debug-everything/SKILL.md:
1. Remove Phase 2.5: Complexity Gate section entirely (Steps 1-5)
2. Remove 'Complexity (from Phase 2.5 complexity gate)' reference from sub-agent dispatch template
3. Add escalation report handling in Phase 6 (Post-Batch Checkpoint) — after fix-bug sub-agents return, parse each result for escalation signals; if escalation detected, re-dispatch that bug at orchestrator level (direct /dso:fix-bug invocation, not sub-agent)

TDD: Task w21-gljg RED tests turn GREEN after this implementation.
