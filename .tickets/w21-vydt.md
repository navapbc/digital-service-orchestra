---
id: w21-vydt
status: closed
deps: []
links: []
created: 2026-03-20T01:14:56Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Add child count to sprint epic list display


## Notes

**2026-03-20T01:15:04Z**

## Context
When a developer runs /dso:sprint without an epic ID, the skill displays a numbered list of epics to choose from. Currently the list shows only priority and title — there's no indication of whether an epic has been decomposed into stories/tasks or is still a bare idea. This forces the developer to tk show individual epics to determine readiness, slowing down the selection process. Adding a child count gives an at-a-glance readiness signal: epics with 0 children need /dso:preplanning or /dso:implementation-plan first, while epics with children are ready for /dso:sprint execution.

## Success Criteria
1. sprint-list-epics.sh output includes a child count for each epic, displayed alongside the existing priority and title
2. Child counts are derived by scanning .tickets/*.md files for parent: frontmatter references — no per-epic tk show calls
3. The child count computation adds no more than 1 second of wall-clock time to the script's execution, even with 100+ ticket files
4. The sprint skill's epic selection display renders the child count inline with each epic entry
5. After delivery, running /dso:sprint on this project shows accurate child counts matching grep -c 'parent: <epic-id>' .tickets/*.md for each displayed epic

## Dependencies
None

## Approach
Single-pass grep of all .tickets/*.md files for parent: references, counted per epic ID, integrated into the existing sprint-list-epics.sh script output.
