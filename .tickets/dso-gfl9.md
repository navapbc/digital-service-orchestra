---
id: dso-gfl9
status: closed
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

## ACCEPTANCE CRITERIA

- [ ] SKILL.md Step 3 uses AskUserQuestion for each command prompt (one at a time)
  Verify: grep -c "AskUserQuestion" plugins/dso/skills/project-setup/SKILL.md | awk '{exit ($1 < 5)}'
- [ ] Each command suggestion includes detection-aware labels ("exists in project" or "convention for <stack>")
  Verify: grep -c "exists in project\|convention for" plugins/dso/skills/project-setup/SKILL.md | awk '{exit ($1 < 3)}'
- [ ] version.file_path and tickets.prefix prompts are included in Step 3
  Verify: grep -q "version.file_path" plugins/dso/skills/project-setup/SKILL.md && grep -q "tickets.prefix" plugins/dso/skills/project-setup/SKILL.md
- [ ] format.extensions and format.source_dirs prompts describe coverage
  Verify: grep -q "format.extensions" plugins/dso/skills/project-setup/SKILL.md && grep -q "format.source_dirs" plugins/dso/skills/project-setup/SKILL.md
- [ ] Tests verify sequential prompt flow and detection-aware suggestions
  Verify: test -f tests/skills/test_project_setup_commands_format.py || test -f tests/skills/test-project-setup-commands-format.sh

## Notes

<!-- note-id: 2yjo0unk -->
<!-- timestamp: 2026-03-20T00:59:32Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: t4fkrfhm -->
<!-- timestamp: 2026-03-20T00:59:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: h8fmrlmx -->
<!-- timestamp: 2026-03-20T01:01:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ (8 tests failing RED before implementation)

<!-- note-id: 85ymtg1p -->
<!-- timestamp: 2026-03-20T01:02:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ (SKILL.md Step 3 rewritten with AskUserQuestion, detection-aware labels, format/version/tickets prompts)

<!-- note-id: 7ohex8eh -->
<!-- timestamp: 2026-03-20T01:02:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ (ruff format ok, ruff check ok, skill-refs ok)

<!-- note-id: r4or3l53 -->
<!-- timestamp: 2026-03-20T01:02:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ All 5 AC criteria verified: AC1 AskUserQuestion>=5 PASS, AC2 detection-aware labels>=3 PASS, AC3 version.file_path+tickets.prefix PASS, AC4 format.extensions+format.source_dirs PASS, AC5 test file exists PASS
