---
id: w21-dksj
status: open
deps: [w21-ahok]
links: []
created: 2026-03-19T03:31:13Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, ADVANCED investigation uses two agents with differentiated lenses and convergence scoring

## Description

**What**: ADVANCED investigation tier — two independent opus agents with differentiated analytical lenses, convergence scoring, and fishbone synthesis.
**Why**: Complex bugs benefit from multiple perspectives. Two agents attacking from different angles (code tracing vs. historical analysis) produce higher-confidence root causes when they converge.
**Scope**:
- IN: Two ADVANCED prompt templates — Agent A (code tracer: execution path tracing, intermediate variable tracking, five whys, hypothesis set from code evidence) and Agent B (historical: timeline reconstruction, fault tree analysis, git bisect, hypothesis set from change history), convergence scoring logic, fishbone synthesis across cause categories (Code Logic, State, Configuration, Dependencies, Environment, Data)
- OUT: Four-agent ESCALATED mode, veto/resolution logic

## Done Definitions

- When this story is complete, an ADVANCED investigation dispatches two independent opus agents with differentiated lenses (code tracer + historical) and merges their findings using convergence scoring
  ← Satisfies: "Each investigation tier uses differentiated sub-agents with specific root cause techniques" (ADVANCED)
- When this story is complete, convergent root causes from both agents receive higher confidence than single-agent findings
  ← Satisfies: "orchestrator applies convergence scoring"
- When this story is complete, divergent findings are synthesized using fishbone analysis across cause categories
  ← Satisfies: "fishbone synthesis across cause categories"

## Considerations

- [Reliability] Graceful handling of sub-agent timeout or malformed output — degrade to single-agent result rather than failing entirely
- [Maintainability] Prompts extend shared base from S2/S3 with tier-specific techniques

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

**2026-03-19T16:17:19Z**

CHECKPOINT: SESSION_END — Implementation tasks created (S4, S7). Remaining stories need execution of impl tasks + further impl planning (S5, S10, S11). Resume with /dso:sprint dso-tmmj --resume
