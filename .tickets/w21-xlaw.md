---
id: w21-xlaw
status: open
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
