---
id: w21-8igi
status: closed
deps: [w21-auwy]
links: []
created: 2026-03-19T03:31:28Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, fix-cascade-recovery retains its emergency brake and hands off to dso:fix-bug

## Description

**What**: Update fix-cascade-recovery to retain its emergency-brake steps (stop, assess git damage, revert decision, circuit breaker reset) and hand off to dso:fix-bug for investigation, removing its own root cause analysis steps.
**Why**: fix-cascade-recovery's unique value is the emergency brake — stopping runaway cascading edits, assessing damage, and deciding whether to revert. Its root cause analysis duplicates what dso:fix-bug does better.
**Scope**:
- IN: fix-cascade-recovery SKILL.md updates — retain Steps 1-2 (stop + revert) and Step 7 (circuit breaker reset), remove Steps 3-5 (research/diagnose/plan), add hand-off to dso:fix-bug after Step 2 with cascade context
- OUT: fix-cascade-recovery circuit breaker mechanism itself, dso:fix-bug scoring logic

## Done Definitions

- When this story is complete, fix-cascade-recovery retains its emergency-brake steps (stop, assess git damage, revert decision) and circuit breaker reset
  ← Satisfies: "fix-cascade-recovery retains its emergency-brake steps"
- When this story is complete, after the emergency brake, fix-cascade-recovery hands off to dso:fix-bug for investigation instead of doing its own root cause analysis
  ← Satisfies: "hands off to dso:fix-bug for investigation; its root cause analysis steps are removed"

## Considerations

- [Reliability] The hand-off must pass cascade context that maps to the 'cascading failure status' dimension (+2) in S1's scoring rubric — not a raw total modifier, but a per-dimension input

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
