---
id: w21-9cvk
status: open
deps: []
links: []
created: 2026-03-20T01:05:48Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# RED: Tests for fix-bug complexity evaluation and escalation report


## Notes

**2026-03-20T01:06:10Z**

## Description
Add 3 test functions to tests/hooks/test-fix-bug-skill.sh:
1. test_fix_bug_skill_complexity_evaluation — grep for 'Step 4.5' heading AND 'complexity-evaluator' reference
2. test_fix_bug_skill_escalation_report — grep for 'Escalation Report' section AND field names 'bug_id', 'investigation_findings'
3. test_fix_bug_skill_subagent_detection — grep for 'running as a sub-agent' AND 'Agent tool'
All 3 tests FAIL (RED) because fix-bug SKILL.md doesn't contain these yet.

TDD: These ARE the RED tests.
