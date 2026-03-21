---
id: w21-nica
status: open
deps: [w21-1as4, w21-cw8j, w21-kezk, w21-1bvu]
links: []
created: 2026-03-21T21:05:12Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-2j6u
---
# Update project docs to reflect dedicated agent extraction

## Description

**What**: Update project documentation to reflect the dedicated agent extraction — CLAUDE.md architecture section, shared rubric file lifecycle, and any docs referencing the old dispatch pattern.
**Why**: After extraction, existing documentation describes a dispatch pattern (loading prompt content into general-purpose tasks) that no longer exists. Stale docs will confuse future agents and developers.
**Scope**:
- IN: Update CLAUDE.md architecture section (list new agents, describe named-agent dispatch). Update or deprecate `skills/shared/prompts/complexity-evaluator.md`. Update references in docs that describe the old dispatch pattern.
- OUT: New documentation files. Changes to code or skill files.

## Done Definitions

- When this story is complete, CLAUDE.md architecture section lists both dedicated agents (dso:complexity-evaluator, dso:conflict-analyzer) and distinguishes between routing-category dispatch (via discover-agents.sh) and named-agent dispatch (via subagent_type)
  ← Satisfies: accurate documentation of agent architecture
- When this story is complete, the shared rubric file (`skills/shared/prompts/complexity-evaluator.md`) is either deprecated with a pointer to the agent definition or removed, with any remaining references updated
  ← Satisfies: no stale documentation
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting and conventions


## Notes

**2026-03-21T21:06:37Z**

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.
