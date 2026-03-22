---
id: dso-917w
status: open
deps: []
links: []
created: 2026-03-22T19:00:20Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-t4k8
---
# As a DSO practitioner, sub-agents receive comprehensive anti-cover-up guidance in active prompt templates

## Description

**What**: Expand SUB-AGENT-BOUNDARIES.md with a comprehensive Prohibited Fix Patterns section covering all five anti-patterns with code examples, rationale, and Do this instead alternatives. Add a matching reinforcement section to task-execution.md (the active sprint sub-agent template).
**Why**: Sub-agents currently see only terse prohibitions without rationale. Adding examples and alternatives gives agents a clear path to legitimate fixes instead of cover-ups.
**Scope**:
- IN: SUB-AGENT-BOUNDARIES.md (expand existing prohibitions), task-execution.md (add new section)
- OUT: Deprecated templates (fix-task-tdd.md, fix-task-mechanical.md) — handled by a separate story. Review-time detection — handled by separate epics (w21-ovpn, w21-ykic).

## Done Definitions

- When this story is complete, SUB-AGENT-BOUNDARIES.md contains a Prohibited Fix Patterns section listing all five anti-patterns (skipping/removing tests, loosening assertions, broad exception handlers, downgrading error severity, commenting out failing code) with code examples, rationale, and concrete Do this instead alternatives
  <- Satisfies: "SUB-AGENT-BOUNDARIES.md existing suppression prohibitions are expanded to cover the same five anti-patterns"
- When this story is complete, task-execution.md contains a Prohibited Fix Patterns section with the same five anti-patterns and alternatives
  <- Satisfies: "Sub-agent prompt templates each include a Prohibited Fix Patterns section"
- When this story is complete, each prohibited pattern's alternative describes a concrete agent action (e.g., fix the failing assertion, trace to root cause)
  <- Satisfies: "Each prohibited pattern's Do this instead alternative describes a concrete action"
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Content must be deduplicated with existing prohibitions in SUB-AGENT-BOUNDARIES.md — merge, do not duplicate

