---
id: w22-xzrw
status: closed
deps: [w22-iig7, w22-q9d2]
links: []
created: 2026-03-20T15:27:54Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Recalibrate Agent Clarity reviewer for epic-level evaluation

## Context
The brainstorm skill's Agent Clarity reviewer (agent-clarity.md) evaluates epic specs using dimension definitions calibrated for task-level work. "Self-contained" asks whether "a developer agent would build the right thing," which reviewers interpret as needing exact commands, file paths, and implementation details. "Success measurable" demands command-level testability. This causes well-written epics to score 3/3 repeatedly until padded with implementation details that belong in /dso:implementation-plan, wasting brainstorm iterations and bloating epic specs with prescriptive detail that constrains downstream planning.

## Success Criteria
1. The self_contained dimension evaluates whether a planner can decompose the spec into stories without asking clarifying questions — not whether a developer can write code from it
2. The success_measurable dimension evaluates whether criteria describe specific, observable outcomes verifiable at the feature level — not whether they specify exact commands or file formats
3. The reviewer does not penalize missing file paths, shell commands, implementation details, or specific data formats — those belong in implementation planning
4. The reviewer does penalize genuinely ambiguous specs: vague outcomes ("improve testing"), undefined jargon, missing edge case coverage, and criteria that describe effort rather than outcomes
5. Before/after validation: the dso-ppwp epic spec (test gate enforcement) scores 4+ on both dimensions with the updated reviewer; the same spec scores below 4 on at least one dimension with the original reviewer

## Dependencies
None

## Approach
Rewrite the dimension definitions and instructions in agent-clarity.md to explicitly target epic-level evaluation. Add anti-patterns that prevent scoring below 4 for implementation-level nits, while preserving the reviewer's ability to flag genuine ambiguity and missing edge case coverage.

## Notes

**2026-03-21T03:51:33Z**

SC5 validation: self_contained=4, success_measurable=5 (epic dso-ppwp). Context fully supports story decomposition without clarifying questions; all 7 success criteria describe specific, observable outcomes at feature level with no vague language.
