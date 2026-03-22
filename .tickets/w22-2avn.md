---
id: w22-2avn
status: open
deps: []
links: []
created: 2026-03-22T06:46:22Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-5ooy
---
# As a DSO practitioner, an aggressive security red team agent reviews diffs for AI-advantaged security concerns

## Description

**What**: Create the security red team reviewer-delta file and agent definition — an aggressive opus agent that reviews diffs for security concerns without ticket context.
**Why**: Maximizes security issue recall with an aggressive detection directive; false-positive filtering is handled by the blue team.
**Scope**:
- IN: reviewer-delta file with 8 AI-advantaged security criteria (authorization completeness, untrusted-input-to-dangerous-sink data flow, fail-open error handling, state machine integrity, privilege escalation, cryptographic misuse, TOCTOU race conditions, trust boundary violations), scrutiny lenses (new entry points, sensitive data exposure), hard exclusion list, anti-manufacturing directive, rationalizations-to-reject list, build via build-review-agents.sh. Output schema documented as explicit contract artifact for blue team consumption.
- OUT: Blue team triage, deterministic tool criteria (explicitly excluded from prompt), dispatch logic

## Done Definitions

- When this story is complete, a security red team reviewer-delta file exists with all 8 security criteria, exclusion lists, and false-positive reduction directives
- When this story is complete, build-review-agents.sh generates the security red team agent from the delta file
- When this story is complete, the red team agent outputs findings in a documented schema that includes per-finding severity, confidence scores, and all fields needed for blue team consumption — this schema is committed as an explicit contract artifact
- When this story is complete, unit tests written and passing for agent build and output schema validation

## Considerations

- [Maintainability] Consistent delta file structure with existing reviewer-delta pattern
- [Reliability] Red team output schema is the contract that Story 5 (blue team) depends on — schema must be explicit and documented

