---
id: w21-nl5m
status: open
deps: [w21-auwy, w21-slh5]
links: []
created: 2026-03-19T03:31:23Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, debug-everything delegates bug resolution to dso:fix-bug

## Description

**What**: Update debug-everything to delegate individual bug and cluster resolution to dso:fix-bug instead of using its own fix-task-tdd.md and fix-task-mechanical.md prompts.
**Why**: debug-everything should be a project-health orchestrator that discovers and triages bugs, then delegates resolution to dso:fix-bug for the actual investigation and fix.
**Scope**:
- IN: debug-everything SKILL.md updates to delegate to dso:fix-bug, fix-task-tdd.md and fix-task-mechanical.md updates or replacement, triage-to-scoring-rubric mapping
- OUT: Other debug-everything phases (diagnostic, triage, validation, merge)

## Done Definitions

- When this story is complete, debug-everything dispatches dso:fix-bug for individual bug resolution instead of using fix-task-tdd.md or fix-task-mechanical.md directly
  ← Satisfies: "debug-everything delegates individual bug and cluster resolution to dso:fix-bug"
- When this story is complete, debug-everything passes bug clusters to dso:fix-bug for unified investigation
  ← Satisfies: "debug-everything delegates cluster resolution to dso:fix-bug"
- When this story is complete, debug-everything passes its triage severity/complexity classification to dso:fix-bug in a way the scoring rubric can consume, avoiding redundant re-classification
  ← Satisfies: SC8 — prevents contradictory routing between debug-everything's triage and fix-bug's scoring

## Considerations

- [Maintainability] Ensure debug-everything's tier system and fix-task prompts are cleanly replaced, not partially duplicated

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
