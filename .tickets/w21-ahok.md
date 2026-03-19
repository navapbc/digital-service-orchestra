---
id: w21-ahok
status: closed
deps: [w21-c4ek]
links: []
created: 2026-03-19T03:31:10Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, INTERMEDIATE investigation gives me deeper analysis with hypothesis elimination and error-detective

## Description

**What**: INTERMEDIATE investigation tier — single opus sub-agent using error-debugging:error-detective (with general-purpose fallback), dependency-ordered code reading, intermediate variable tracking, five whys, hypothesis generation + elimination, self-reflection.
**Why**: Intermediate-severity bugs need deeper investigation than BASIC provides — dependency-ordered reading and hypothesis elimination significantly improve root cause accuracy.
**Scope**:
- IN: INTERMEDIATE investigation prompt template (extending BASIC base), error-detective sub-agent routing via discover-agents.sh with graceful fallback to general-purpose, fallback investigation-specific prompt covering same root cause techniques, INSTALL.md update adding error-debugging as recommended plugin
- OUT: Multi-agent investigation (ADVANCED/ESCALATED), convergence logic

## Done Definitions

- When this story is complete, an INTERMEDIATE investigation dispatches an opus sub-agent using error-debugging:error-detective when available, falling back to general-purpose with an investigation-specific prompt that covers the same root cause techniques
  ← Satisfies: "error-debugging plugin is added to INSTALL.md as a recommended plugin; when unavailable, investigation sub-agents fall back to general-purpose"
- When this story is complete, the investigation sub-agent applies dependency-ordered code reading, intermediate variable tracking, hypothesis generation + elimination, and self-reflection
  ← Satisfies: "Each investigation tier uses differentiated sub-agents with specific root cause techniques" (INTERMEDIATE)
- When this story is complete, INSTALL.md lists error-debugging as a recommended plugin for enhanced investigation
  ← Satisfies: "error-debugging plugin is added to INSTALL.md"

## Considerations

- [Reliability] Fallback prompt must cover same root cause techniques as error-detective — test both paths
- [Maintainability] Prompt extends BASIC template with additional techniques, not a copy-paste

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
