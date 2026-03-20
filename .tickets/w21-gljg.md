---
id: w21-gljg
status: open
deps: []
links: []
created: 2026-03-20T01:05:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# RED: Tests for debug-everything Phase 2.5 removal + escalation handling


## Notes

**2026-03-20T01:06:19Z**

## Description
Create tests/scripts/test-debug-everything-escalation.sh with 3 tests:
1. test_no_phase_2_5 — verify debug-everything SKILL.md does NOT contain 'Phase 2.5: Complexity Gate'
2. test_escalation_handling_present — verify SKILL.md contains escalation report handling with 're-dispatch' or 'orchestrator' references
3. test_no_phase_2_5_dispatch_ref — verify dispatch template does NOT reference 'Phase 2.5 complexity gate'
All 3 FAIL (RED).

TDD: These ARE the RED tests.
