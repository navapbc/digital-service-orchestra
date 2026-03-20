---
id: dso-q2ev
status: closed
deps: [dso-uc2d]
links: []
created: 2026-03-20T00:09:44Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-kknz
---
# As a developer setting up DSO, the setup creates .claude/dso-config.conf

## Description

**What**: Update `dso-setup.sh` to create config at the new `.claude/dso-config.conf` path.
**Why**: New project installations must use the new path from the start so developers never encounter the old location.
**Scope**:
- IN: `dso-setup.sh` config creation logic, host-project templates, user-facing guidance strings in echo statements, setup tests
- OUT: Config resolution logic (Story dso-uc2d), doc/reference cleanup (separate story)

## Done Definitions

- When this story is complete, `dso-setup.sh` creates `.claude/dso-config.conf` in host projects and does not create `workflow-config.conf`
  ← Satisfies: "dso-setup.sh creates .claude/dso-config.conf in host projects"
- When this story is complete, unit tests written and passing for all new or modified setup logic

## Considerations

- [Testing] Existing setup test fixtures reference old paths — update all fixture configs to use new path and filename.

