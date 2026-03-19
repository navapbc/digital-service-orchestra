---
id: w21-6fir
status: closed
deps: [w21-auwy, w21-c4ek, w21-ahok, w21-dksj, w21-9pp1, w21-slh5, w21-nl5m, w21-1m1i, w21-8igi, w21-u4ym]
links: []
created: 2026-03-19T03:31:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-tmmj
---
# Update project docs to reflect dso:fix-bug skill

## Description

**What**: Update CLAUDE.md and any other existing documentation that references tdd-workflow to point to dso:fix-bug.
**Why**: CLAUDE.md is the primary routing document for agents. If it still references tdd-workflow, agents will bypass the new skill entirely.
**Scope**:
- IN: CLAUDE.md Quick Start dispatch table (Bug fix → dso:fix-bug), architecture section, quick reference table, never-do rules, Common Fixes table; any other existing docs referencing tdd-workflow
- OUT: Creating new documentation files

## Done Definitions

- When this story is complete, CLAUDE.md references dso:fix-bug as the canonical bug-fix workflow in the Quick Start dispatch table, architecture section, quick reference, and Common Fixes table
  ← Satisfies: "tdd-workflow is deprecated with a forward pointer to dso:fix-bug"
- When this story is complete, all existing documentation that references tdd-workflow is updated with forward pointers to dso:fix-bug
  ← Satisfies: SC1

## Considerations

- [Maintainability] Follow .claude/docs/DOCUMENTATION-GUIDE.md for formatting

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

**2026-03-19T03:35:28Z**

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.

**2026-03-19T16:17:19Z**

CHECKPOINT: SESSION_END — Implementation tasks created (S4, S7). Remaining stories need execution of impl tasks + further impl planning (S5, S10, S11). Resume with /dso:sprint dso-tmmj --resume
