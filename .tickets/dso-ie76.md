---
id: dso-ie76
status: open
deps: [dso-lc3c, dso-rc4j]
links: []
created: 2026-03-22T16:33:31Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-oo34
---
# Update project docs to reflect RED test writer agent

See ticket notes for full story body.


## Notes

<!-- note-id: ll0am4w4 -->
<!-- timestamp: 2026-03-22T16:33:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Description

**What**: Update existing project documentation to reflect the new RED test writer agent, tdd_red_test routing category, and workflow dispatch changes.
**Why**: Agents read CLAUDE.md at session start — stale documentation causes agents to use the old inline test-writing approach.
**Scope**:
- IN: CLAUDE.md architecture section (new agent, routing category), CLAUDE.md quick reference table, named-agent dispatch documentation updated to include tdd_red_test
- OUT: New documentation files

## Done Definitions

- When this story is complete, CLAUDE.md architecture section describes the RED test writer agent and tdd_red_test routing category
  Satisfies SC1 (documentation aspect)
- When this story is complete, CLAUDE.md quick reference includes the new agent and its dispatch pattern

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.
