---
id: dso-pu9c
status: open
deps: []
links: []
created: 2026-03-22T23:01:42Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-d63r
---
# As a DSO practitioner, brainstorm stress-tests my epic spec through red/blue team scenario analysis scaled to complexity

## Description

**What**: Add a red/blue team scenario analysis phase to `/dso:brainstorm` that generates hypothetical usage scenarios across runtime, deployment, and configuration categories, then filters out impossible scenarios via a blue team pass.
**Why**: Critical edge cases and failure modes slip through planning and become serious bugs in completed epics. Scenario analysis catches spec-level gaps before stories are created.
**Scope**:
- IN: Red team scenario generation (timeouts, race conditions, conflicts, out-of-order operations, misuse, first-time setup, environment configuration, CI/CD integration), blue team filter (drops impossible scenarios given codebase + proposed design), complexity scaling with documented thresholds, Scenario Analysis section in epic spec output
- OUT: Research phase (separate story), approval gate (separate story), preplanning research (separate story)

## Done Definitions

- When this story is complete, brainstorm generates hypothetical usage scenarios across runtime, deployment, and configuration categories, scaled to the epic's complexity
  ← Satisfies: "brainstorm includes a red/blue team scenario analysis phase that generates hypothetical usage scenarios"
- When this story is complete, a blue team filter evaluates each scenario against the codebase and proposed design, dropping scenarios that are impossible
  ← Satisfies: "with a blue team filter that drops scenarios impossible given the codebase and proposed design"
- When this story is complete, the epic spec contains a dedicated Scenario Analysis section listing surviving scenarios with structured summaries (if analysis ran)
  ← Satisfies: "epic spec contains a dedicated Scenario Analysis section"
- When this story is complete, the skill file documents the complexity threshold at which scenario analysis activates (e.g., always for COMPLEX, N scenarios for MODERATE, skip for TRIVIAL) and specifies how complexity is determined before the Phase 3 evaluator dispatch
- When this story is complete, the brainstorm scenario analysis is clearly differentiated from preplanning's adversarial review (Phase 2.5) — brainstorm scenarios target epic-level spec gaps (edge cases, failure modes, missing constraints) while preplanning adversarial review targets cross-story interaction gaps (shared state, conflicting assumptions, dependency gaps)
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Brainstorm skill is 334 lines — structure scenario analysis as clearly bounded section or reference separate prompt file
- [Performance] Scenario generation + blue team filtering is a two-pass process — consider token cost for complex epics

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

