---
id: w21-c4ek
status: closed
deps: [w21-auwy]
links: []
created: 2026-03-19T03:31:08Z
type: story
priority: 0
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, BASIC investigation gives me structured root cause analysis with five whys before any fix

## Description

**What**: BASIC investigation tier — single sonnet sub-agent with structured localization (file→class→line), five whys, self-reflection. Pre-loaded context before dispatch.
**Why**: This is the first investigation tier, enabling the skill to do more than just route — agents now investigate before fixing, even for simple bugs.
**Scope**:
- IN: BASIC investigation prompt template, context pre-loading logic (existing failing tests, stack traces, commit history, prior fix attempts), structured RESULT report format (conforming to S1's schema), anti-patterns table, discovery file protocol implementation (conforming to S1's contract)
- OUT: INTERMEDIATE/ADVANCED/ESCALATED tiers, error-detective integration, multi-agent convergence

## Done Definitions

- When this story is complete, a BASIC investigation dispatches a sonnet sub-agent that receives pre-loaded context (failing tests, stack traces, commit history) and applies structured localization + five whys before reporting a root cause
  ← Satisfies: "Each investigation tier uses differentiated sub-agents with specific root cause techniques" (BASIC)
- When this story is complete, the investigation sub-agent produces a structured RESULT report conforming to S1's schema with ROOT_CAUSE, confidence level, and proposed fix
  ← Satisfies: "Investigation sub-agents are given pre-loaded context before dispatch"

## Considerations

- [Testing] Prompt template must be testable via mock sub-agent responses
- [Maintainability] Prompt should be composable — shared base elements that higher tiers extend, not a standalone template

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
