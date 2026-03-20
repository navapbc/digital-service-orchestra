---
id: w21-nyu9
status: open
deps: []
links: []
created: 2026-03-20T01:05:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-25vk
---
# Update shared complexity evaluator routing table + tests


## Notes

**2026-03-20T01:06:28Z**

## Description
1. Edit plugins/dso/skills/shared/prompts/complexity-evaluator.md — add fix-bug entry to Context-Specific Routing table: '| /dso:fix-bug post-investigation | TRIVIAL/MODERATE proceed to fix, COMPLEX creates epic | Post-investigation evaluation when fix scope is known |'
2. Edit tests/scripts/test-complexity-gate.sh — add test function test_routing_table_contains_fix_bug

test-exempt: Unit exemption criterion 3 — adds single markdown table row to static routing lookup table with no conditional logic.
