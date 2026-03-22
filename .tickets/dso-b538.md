---
id: dso-b538
status: open
deps: [dso-bxng]
links: []
created: 2026-03-21T23:20:14Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-ovpn
---
# As a DSO practitioner, the Deep Sonnet C reviewer applies deep hygiene, design, and maintainability checks


## Notes

<!-- note-id: qbufm2gh -->
<!-- timestamp: 2026-03-21T23:21:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create the reviewer-delta-deep-hygiene-design-maint.md checklist for the Deep tier Sonnet C (hygiene + design + maintainability specialist) reviewer.

**Why**: Deep tier reviews high-complexity changes. Sonnet C owns three structural dimensions — the qualities that prevent long-term codebase decay. No ticket context needed because structural quality is ticket-independent.

## Acceptance Criteria

- When this story is complete, reviewer-delta-deep-hygiene-design-maint.md includes all Standard hygiene/design/maintainability criteria plus:
  - Flag functions where branching depth suggests extraction opportunities
  - Evaluate whether new abstractions follow single responsibility
  - Flag in-place mutation of shared data structures when immutable patterns are established in surrounding code
- When this story is complete, the checklist includes no ticket context instructions (structural quality is ticket-independent)
- When this story is complete, build-review-agents.sh regenerates the deep hygiene/design/maintainability reviewer agent successfully

