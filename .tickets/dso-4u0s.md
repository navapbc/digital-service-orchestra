---
id: dso-4u0s
status: open
deps: [dso-fj1t]
links: []
created: 2026-03-22T03:27:34Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-d3gr
---
# As a developer, epic closure is blocked until all RED markers are removed from .test-index

## Description

**What**: Add a check that prevents closing an epic when .test-index still contains [RED] markers for stories in that epic. This ensures all RED tests have been implemented and pass before work is considered done.
**Why**: RED markers are transient — they should not persist beyond the epic that created them. Enforcing removal at closure ensures no gaps in test coverage survive the sprint.
**Scope**:
- IN: Epic closure validation that scans .test-index for RED markers, clear error message listing which entries still have markers
- OUT: Automatic marker removal (agents must explicitly remove markers after implementation)

## Done Definitions

- When this story is complete, attempting to close an epic that has .test-index entries with RED markers produces a clear error listing the stale markers
  ← Satisfies: "Epic closure is blocked until all RED markers are removed from .test-index"
- When this story is complete, closing an epic with no RED markers in .test-index succeeds normally
  ← Satisfies: backward compatibility
- When this story is complete, unit tests are written and passing for all new or modified logic

## Considerations

- [Reliability] The check must scan all .test-index entries, not just entries associated with the epic's stories — RED markers from this epic could reference any source file

