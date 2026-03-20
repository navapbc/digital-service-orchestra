---
id: w21-ofew
status: closed
deps: [w21-xlaw]
links: []
created: 2026-03-20T01:21:30Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-vydt
---
# Update sprint SKILL.md display format for child count


## Notes

**2026-03-20T01:21:52Z**

## Description
Update plugins/dso/skills/sprint/SKILL.md 'If No Epic ID Provided' section:
1. Document the new 4-field tab-separated output format from sprint-list-epics.sh
2. Update the display template to show child counts inline with each epic entry

test-exempt: Unit exemption criterion 3 — modifying static documentation/skill prose with no conditional logic.

## ACCEPTANCE CRITERIA

- [ ] SKILL.md documents the 4-field tab-separated format (id, priority, title, child_count)
  Verify: grep -q "child_count\|child.count\|children" plugins/dso/skills/sprint/SKILL.md
- [ ] SKILL.md display template shows child count inline with each epic
  Verify: grep -q "children\|tasks\|child" plugins/dso/skills/sprint/SKILL.md

## File Impact

### Files to modify
- plugins/dso/skills/sprint/SKILL.md (update epic display format documentation)

**2026-03-20T19:35:27Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T19:35:47Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T19:35:51Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-20T19:36:19Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T19:36:31Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T19:36:34Z**

CHECKPOINT 6/6: Done ✓
