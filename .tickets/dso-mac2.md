---
id: dso-mac2
status: open
deps: []
links: []
created: 2026-03-22T23:01:23Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-d63r
---
# As a DSO practitioner, brainstorm conducts web research when bright-line conditions are met, when I request it, or when the agent judges it valuable

## Description

**What**: Add a research phase to the `/dso:brainstorm` skill that uses WebSearch/WebFetch to find prior art, best practices, and expert insights, triggered by defined bright-line conditions, agent judgment, or user request.
**Why**: When research is deferred to sprint execution, agents diverge from user intent. Conducting research during brainstorm ensures the epic spec is informed by external knowledge before stories are created.
**Scope**:
- IN: Research phase in brainstorm skill, bright-line trigger conditions (enumerated list of at least three with examples), agent-judgment trigger guidance paragraph, WebSearch/WebFetch integration, Research Findings section in epic spec output with defined structure, graceful degradation when search fails
- OUT: Preplanning research (separate story), approval gate (separate story), scenario analysis (separate story)

## Done Definitions

- When this story is complete, the brainstorm skill includes a research phase that uses WebSearch/WebFetch to find prior art, best practices, and expert insights when triggered by bright-line conditions, agent judgment, or user request
  ← Satisfies: "brainstorm includes a research phase that triggers on defined bright-line conditions, agent judgment for unanticipated cases, or user requests"
- When this story is complete, the brainstorm skill file contains an enumerated list of at least three named bright-line trigger conditions, each with a one-sentence example illustrating when the condition applies, plus a paragraph describing how the agent decides to trigger research outside those explicit conditions
  ← Satisfies: "bright-line conditions for triggering web research are documented in the brainstorm skill with clear examples"
- When this story is complete, the epic spec contains a dedicated Research Findings section with structured summaries after brainstorm completes (if research was triggered), using a defined item-level structure (trigger condition name, query summary, source URLs, key insight) documented in the skill file or a referenced prompt file
  ← Satisfies: "epic spec contains a dedicated Research Findings section"
- When this story is complete, if WebSearch/WebFetch fails, brainstorm continues without research rather than blocking the workflow
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Brainstorm skill is 334 lines — structure research phase as clearly bounded inline section or reference separate prompt file
- [Reliability] WebSearch/WebFetch may fail or return low-quality results — graceful degradation required
- [Performance] Web research adds latency and token cost — bright-line triggers prevent unnecessary research on simple epics

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

