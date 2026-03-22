---
id: w22-agl5
status: open
deps: [w22-2avn, w22-7r1n, w22-53cg]
links: []
created: 2026-03-22T06:47:24Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-5ooy
---
# As a DSO practitioner, overlay findings enter the resolution loop and create tracking tickets for minor issues

## Description

**What**: Integrate overlay findings into the existing resolution loop and tracking ticket path.
**Why**: Ensures overlay findings follow the same lifecycle as standard review findings without new machinery.
**Scope**:
- IN: Overlay findings enter the autonomous resolution loop from w21-ovpn, minor findings create tracking tickets, findings use existing severity scale
- OUT: Resolution loop implementation (w21-ovpn dependency), overlay agent definitions

## Done Definitions

- When this story is complete, overlay findings at critical or important severity enter the autonomous resolution loop and block the commit until resolved
- When this story is complete, overlay findings at minor severity create tracking tickets without blocking
- When this story is complete, overlay findings are aggregated by the dispatch orchestrator and written through the existing single-writer path (write-reviewer-findings.sh) to preserve the single-writer invariant — overlay agents do not write to reviewer-findings.json directly
- When this story is complete, unit tests written and passing for findings integration and single-writer compliance

## Considerations

- [Reliability] Single-writer invariant for reviewer-findings.json must be preserved — CLAUDE.md rule 18 restricts writes. Overlay findings must be aggregated by the orchestrator before writing.

