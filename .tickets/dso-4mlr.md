---
id: dso-4mlr
status: closed
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


## ACCEPTANCE CRITERIA

- [ ] CLAUDE.md documents .test-index RED marker format `[first_red_test_name]`
  Verify: grep -q '\[.*red.*test.*\]\|RED marker\|first_red_test' CLAUDE.md
- [ ] CLAUDE.md documents the convention that RED tests go at the end of test files
  Verify: grep -q 'RED test.*end\|end.*test file\|appended.*end' CLAUDE.md
- [ ] CLAUDE.md documents epic closure enforcement of RED marker removal
  Verify: grep -q 'epic.*closure.*RED\|RED.*marker.*removed\|blocked.*RED' CLAUDE.md
- [ ] No new documentation files created (update existing only)
  Verify: test "$(git ls-files --others --exclude-standard | grep -c '\.md$')" -eq 0

## Notes

<!-- note-id: 8xcam8ba -->
<!-- timestamp: 2026-03-22T03:27:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.

<!-- note-id: l74qj0tr -->
<!-- timestamp: 2026-03-22T05:42:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: qek6vova -->
<!-- timestamp: 2026-03-22T05:43:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: cl7rln3b -->
<!-- timestamp: 2026-03-22T05:43:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: vjj0aec1 -->
<!-- timestamp: 2026-03-22T05:43:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: dxeiuii7 -->
<!-- timestamp: 2026-03-22T05:43:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: x6welsg3 -->
<!-- timestamp: 2026-03-22T05:43:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
