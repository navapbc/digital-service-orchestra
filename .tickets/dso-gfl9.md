---
id: dso-gfl9
status: open
deps: 
  - dso-r2es
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, I configure commands and format settings one question at a time with detection-aware suggestions

## Description

**What**: Rewrite the commands and format section of the wizard to ask one question at a time using AskUserQuestion. Each command suggestion indicates whether the target exists in the project (verified by detection script) or is a standard convention for the detected stack. Format settings describe which file extensions and directories are covered. Also prompt for version.file_path and tickets.prefix.
**Why**: Users need to understand what each suggestion is based on to make informed decisions, and simultaneous questions are overwhelming.
**Scope**:
- IN: Sequential prompts for commands.test, commands.test_unit, commands.lint, commands.format, commands.format_check, commands.validate, format.extensions, format.source_dirs, version.file_path, tickets.prefix
- OUT: CI config (separate story), infrastructure keys (separate story), dependency prompts (separate story)

## Done Definitions

- When this story is complete, the wizard asks one command question at a time using AskUserQuestion
  ← Satisfies: "Setup wizard asks one question at a time, using AskUserQuestion where appropriate"
- When this story is complete, each command suggestion is labeled as "exists in project" (verified target) or "convention for <stack>" (standard but not yet implemented)
  ← Satisfies: "Command suggestions indicate whether each target exists in the project or is a standard convention for the detected stack"
- When this story is complete, format settings describe which file extensions and directories are covered by the proposed configuration
  ← Satisfies: "Format settings describe which file extensions and directories are covered by the proposed configuration"
- When this story is complete, version.file_path and tickets.prefix are prompted during setup
  ← Satisfies: "version.file_path, tickets.prefix ... are prompted when project context indicates they are relevant"
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Depends on detection script output schema from dso-r2es
- [Scope] This story must also own the Jira integration prompts (jira.project + env var guidance) and monitoring.tool_errors prompt from the existing SKILL.md wizard — no other story claims these sections
- [Maintainability] This story modifies SKILL.md Step 3. Stories dso-6576, dso-bzvu, dso-6dp5, dso-jvjw also modify SKILL.md — recommend sequential implementation to avoid merge conflicts

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
