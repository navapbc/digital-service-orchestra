---
id: w21-ha0r
status: open
deps: [w21-ifgr, w21-n1rq]
links: []
created: 2026-03-21T01:41:33Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-p7aa
---
# Update project docs to reflect batched test enforcement

## Description

**What**: One-time edit to CLAUDE.md and SUB-AGENT-BOUNDARIES.md: add broad test commands to the Never Do These list, replace quick-reference/example usage with validate.sh
**Why**: Removes counterproductive guidance that teaches agents about prohibited commands in quick-reference tables and examples — prohibited commands should only appear on explicit prohibition lists
**Scope**:
- IN: CLAUDE.md edits (Never Do These + quick-reference table), SUB-AGENT-BOUNDARIES.md edits
- OUT: Skill prompt optimization (deferred to dso-l2ct, dso-zj3r)

## Done Definitions

- When this story is complete, for make test-unit-only and make test-e2e, grep -n in CLAUDE.md and SUB-AGENT-BOUNDARIES.md returns zero matches outside lines between ### Never Do These and the next ### heading
  ← Satisfies: "CLAUDE.md and SUB-AGENT-BOUNDARIES.md are updated in a one-time edit"

## Considerations

- Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions


## Notes

**2026-03-21T01:41:40Z**

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.
