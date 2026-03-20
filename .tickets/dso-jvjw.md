---
id: dso-jvjw
status: open
deps: 
  - dso-r2es
  - dso-6576
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, template files are merged or supplemented instead of blindly overwriting

## Description

**What**: Replace blind file copying with smart handling: (1) CLAUDE.md and KNOWN-ISSUES.md warn if they already exist and offer to supplement (appending DSO scaffolding sections without duplicating existing scaffolding). (2) .pre-commit-config.yaml merges DSO hooks into the existing file instead of overwriting. (3) CI workflow file (.github/workflows/ci.yml) is not copied if the project already has a CI workflow under any name; instead, existing workflows are analyzed for missing guards (lint/format/test) and the user is offered to add them.
**Why**: Overwriting existing files destroys user work. Blindly copying a ci.yml when ci-pipeline.yml already exists creates confusion.
**Scope**:
- IN: Smart CLAUDE.md/KNOWN-ISSUES.md supplement logic, .pre-commit-config.yaml hook merging, CI workflow guard analysis and selective addition
- OUT: Detection of existing files (handled by dso-r2es), CI config key prompting (handled by dso-6576)

## Done Definitions

- When this story is complete, attempting to copy CLAUDE.md or KNOWN-ISSUES.md when they already exist produces a warning and offers to supplement instead of overwrite, without duplicating scaffolding
  ← Satisfies: "CLAUDE.md and KNOWN-ISSUES.md overwrites produce a warning with an option to supplement instead, without duplicating scaffolding"
- When this story is complete, .pre-commit-config.yaml merges DSO hooks into an existing file rather than overwriting it
  ← Satisfies: "Pre-commit config merges hooks into an existing .pre-commit-config.yaml rather than overwriting"
- When this story is complete, existing CI workflows are analyzed for lint/format/test guards and users are offered to add missing guards rather than copying a new ci.yml
  ← Satisfies: "Existing CI workflows are analyzed for lint/format/test guards before offering to add them"
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] CLAUDE.md supplement must detect existing DSO sections to avoid duplication — use section header markers
- [Reliability] Pre-commit YAML merge must preserve existing hook ordering and repo entries
- [Maintainability] CI guard analysis must consume detection output from dso-r2es rather than re-parsing workflow YAML files, to avoid divergent heuristics

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
