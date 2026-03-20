---
id: dso-6dp5
status: open
deps: 
  - dso-r2es
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, each optional dependency is prompted individually with functionality explanation

## Description

**What**: Replace the single "show install instructions?" question with individual per-dependency prompts. Each question explains what functionality is unavailable without that dependency. Dependencies already detected as installed are skipped entirely (no prompt shown).
**Why**: Users need to make informed per-dependency decisions. Bundling them hides the tradeoffs, and offering to install something already present is confusing.
**Scope**:
- IN: Individual prompts for acli (Jira CLI integration), PyYAML (legacy YAML config support), pre-commit (git hook management), and any other optional dependencies. Skip prompt for already-installed deps.
- OUT: Required dependencies (handled by dso-setup.sh prerequisite checks)

## Done Definitions

- When this story is complete, each optional dependency is prompted as an individual question with an explanation of what functionality is unavailable without it
  ← Satisfies: "Each optional dependency is prompted individually with an explanation of what functionality is unavailable without it"
- When this story is complete, dependencies already detected as installed are not prompted for installation
  ← Satisfies: "dependencies already installed are not offered for installation"
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Depends on detection script output for installed dependency status from dso-r2es
- [UX] acli prompt should be skipped if user declined Jira integration earlier in the wizard — check detection output or wizard state for Jira indicators before prompting

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
