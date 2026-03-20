---
id: dso-48fu
status: open
deps: 
  - dso-gfl9
  - dso-6576
  - dso-bzvu
  - dso-6dp5
  - dso-jvjw
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, dryrun preview is a flat outcome list and conclusion shows manual steps

## Description

**What**: Rewrite the dryrun preview to present a flat list of outcomes ("will write X to workflow-config.conf", "will merge hooks into .pre-commit-config.yaml", "will supplement CLAUDE.md with DSO sections") without distinguishing which component (script vs skill) performs each action. At setup conclusion, display a list of manual commands the user should run and environment exports they should add (e.g., Jira env vars) that the setup did not perform.
**Why**: Users don't care whether a script or skill makes the change. They need to know what will happen and what they still need to do manually.
**Scope**:
- IN: Unified dryrun preview format, conclusion with manual steps/exports. Jira env vars shown only in conclusion (not dryrun preview) since the skill does not add them to the shell profile.
- OUT: Individual wizard question flow (earlier stories), detection logic (dso-r2es)

## Done Definitions

- When this story is complete, the dryrun preview presents a flat list of outcomes without distinguishing script vs skill operations
  ← Satisfies: "Dryrun preview presents a flat list of outcomes without distinguishing script vs skill operations"
- When this story is complete, the setup conclusion displays a list of manual commands and environment exports the user still needs to perform
  ← Satisfies: "Setup conclusion displays a list of manual commands and environment exports the user still needs to perform"
- When this story is complete, each wizard section (from upstream stories) produces a list of planned actions that the dryrun preview can collect and display
  ← Satisfies: cross-story integration contract (adversarial review finding)
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Preview format depends on output from all earlier wizard stories being finalized
- [Maintainability] Upstream wizard stories must use a consistent pattern for registering planned actions so this story can aggregate them

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
