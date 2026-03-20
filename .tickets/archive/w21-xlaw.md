---
id: w21-xlaw
status: closed
deps: [w21-8ady]
links: []
created: 2026-03-20T01:21:29Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-vydt
---
# GREEN: Add child count to sprint-list-epics.sh output


## Notes

**2026-03-20T01:21:50Z**

## Description
1. Edit sprint-list-epics.sh: Before the Python classification pass, scan .tickets/*.md for parent: frontmatter lines (single grep call), count per parent ID, pass counts into the Python block. Add child count as 4th tab-separated field in output.
2. Update Test 14 in test-sprint-list-epics.sh to expect 4 fields instead of 3.
Note: The only consumer of this output format is sprint/SKILL.md, updated in the next task.

TDD: Task w21-8ady RED tests turn GREEN after this implementation.

## ACCEPTANCE CRITERIA

- [ ] sprint-list-epics.sh output includes a 4th tab-separated child count field
  Verify: bash tests/scripts/test-sprint-list-epics.sh 2>&1 | grep -q "PASSED.*17"
- [ ] All 17 tests pass (0 failures) in test-sprint-list-epics.sh
  Verify: bash tests/scripts/test-sprint-list-epics.sh 2>&1 | grep -q "FAILED: 0"
- [ ] Child counts are derived from .tickets/*.md parent: frontmatter (grep-based)
  Verify: grep -q "parent:" plugins/dso/scripts/sprint-list-epics.sh

## File Impact

### Files to modify
- plugins/dso/scripts/sprint-list-epics.sh (add child count computation and 4th field output)
- tests/scripts/test-sprint-list-epics.sh (update Test 14 to expect 4 fields)

**2026-03-20T19:24:19Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T19:24:29Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T19:25:19Z**

CHECKPOINT 3/6: Tests written (none required — RED tests already exist from w21-8ady) ✓

**2026-03-20T19:25:21Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T19:25:38Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T19:26:20Z**

CHECKPOINT 6/6: Done ✓
