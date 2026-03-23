---
id: dso-5bvd
status: open
deps: [dso-mac2]
links: []
created: 2026-03-22T23:02:20Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-d63r
---
# As a DSO practitioner, preplanning resolves story-level research gaps before handing off to sprint

## Description

**What**: Add a story-level research phase to `/dso:preplanning` that fires when decomposition reveals gaps requiring investigation, using WebSearch/WebFetch to resolve them before sprint execution.
**Why**: Some questions only emerge during story decomposition and cannot be anticipated at the epic level. Resolving them during preplanning prevents agents from diverging during sprint execution due to missing context.
**Scope**:
- IN: Story-level research phase in preplanning, trigger conditions (undocumented API behavior, assumed data formats, low agent confidence), WebSearch/WebFetch integration, Research Notes section in story specs using the same item-level structure as brainstorm's Research Findings, graceful degradation
- OUT: Epic-level research (separate story), scenario analysis (separate story), approval gate (separate story)

## Done Definitions

- When this story is complete, preplanning includes a research phase that fires when decomposition reveals gaps requiring investigation (e.g., a story depends on an external API whose behavior is undocumented, a story assumes a data format not described in the epic context, or agent confidence on a key implementation decision is low), resolving them before sprint execution
  ← Satisfies: "preplanning includes a story-level research phase that fires when decomposition reveals gaps"
- When this story is complete, each story spec that triggered story-level research contains a Research Notes section with structured summaries using the same item-level structure (trigger condition name, query summary, source URLs, key insight) as the brainstorm Research Findings section
  ← Satisfies: "each story spec that triggered story-level research contains a Research Notes section"
- When this story is complete, if WebSearch/WebFetch fails, preplanning continues without research rather than blocking the workflow
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Preplanning skill is 800 lines — research phase must be minimal and clearly bounded to avoid further bloat
- [Reliability] WebSearch/WebFetch may fail — graceful degradation required (continue without research)
- [Performance] Research adds latency and token cost — trigger conditions must be selective to avoid unnecessary research

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

