---
id: dso-fqye
status: in_progress
deps: [dso-6r3o]
links: []
created: 2026-03-22T19:17:01Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-uu13
---
# Update project docs to reflect CI ticket removal

## Description

**What**: Update CLAUDE.md rule #3 to remove the reference to auto-created tracking issues, since the CI auto-creation pattern has been removed.
**Why**: The rule currently states "Tracking issues are auto-created by commit-failure-tracker hook" — with CI auto-creation removed, this must be reworded to reflect that agents are responsible for creating tracking issues manually when needed.
**Scope**:
- IN: Update CLAUDE.md rule #3 in "Never Do These" section
- OUT: No changes to advisory hooks or other documentation

## Done Definitions

- When this story is complete, CLAUDE.md rule #3 no longer references auto-creation of tracking issues
  ← Satisfies: "CLAUDE.md rule #3 is updated to remove the auto-creation reference"

## Considerations

- [Maintainability] Ensure the updated rule still conveys the intent that failures should be tracked — just not auto-created by CI


## Notes

<!-- note-id: 9vxh7g9z -->
<!-- timestamp: 2026-03-22T19:17:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.
