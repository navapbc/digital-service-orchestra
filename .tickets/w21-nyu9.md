---
id: w21-nyu9
status: in_progress
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

## File Impact
- plugins/dso/skills/shared/prompts/complexity-evaluator.md (modify — add routing table row)
- tests/scripts/test-complexity-gate.sh (modify — add test_routing_table_contains_fix_bug function)

## ACCEPTANCE CRITERIA
- [ ] complexity-evaluator.md contains fix-bug routing entry
  Verify: grep -q 'fix-bug post-investigation' plugins/dso/skills/shared/prompts/complexity-evaluator.md
- [ ] test-complexity-gate.sh contains test_routing_table_contains_fix_bug function
  Verify: grep -q 'test_routing_table_contains_fix_bug' tests/scripts/test-complexity-gate.sh
- [ ] New test passes
  Verify: bash tests/scripts/test-complexity-gate.sh 2>&1 | grep -q 'PASS'

**2026-03-20T01:21:48Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T01:22:00Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T01:22:32Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T01:22:34Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T01:24:11Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T01:24:11Z**

CHECKPOINT 6/6: Done ✓
