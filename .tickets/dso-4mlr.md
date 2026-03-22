---
id: dso-4mlr
status: open
deps: [dso-fj1t, dso-4u0s]
links: []
created: 2026-03-22T03:27:46Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-d3gr
---
# Update project docs to reflect RED test gate tolerance

## Description

**What**: Update CLAUDE.md and relevant workflow docs to document the RED marker convention, .test-index format extension, and the TDD workflow for writing RED tests.
**Why**: Future agents need to know about the RED marker convention to use it correctly when writing TDD tests.
**Scope**:
- IN: CLAUDE.md test gate section update, COMMIT-WORKFLOW.md update if record-test-status.sh behavior changed
- OUT: New documentation files (update existing only)

## Done Definitions

- When this story is complete, CLAUDE.md documents the .test-index RED marker format and the convention that RED tests go at the end of test files
  ← Satisfies: "The RED marker is specified in .test-index as the name of the first RED test function"
- When this story is complete, the TDD workflow section documents how agents should add and remove RED markers during sprint work
  ← Satisfies: "Epic closure is blocked until all RED markers are removed"


## Notes

<!-- note-id: 8xcam8ba -->
<!-- timestamp: 2026-03-22T03:27:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.
