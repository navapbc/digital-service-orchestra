---
id: dso-b7nb
status: open
deps: [dso-bxng]
links: []
created: 2026-03-21T23:20:11Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-ovpn
---
# As a DSO practitioner, the Deep Sonnet A reviewer applies deep correctness checks with acceptance criteria validation


## Notes

<!-- note-id: 6sefb1v1 -->
<!-- timestamp: 2026-03-21T23:21:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create the reviewer-delta-deep-correctness.md checklist for the Deep tier Sonnet A (correctness specialist) reviewer.

**Why**: Deep tier reviews high-complexity changes (classifier score 7+). Sonnet A owns correctness with full ticket context, enabling acceptance criteria validation that other reviewers can't perform.

## Acceptance Criteria

- When this story is complete, reviewer-delta-deep-correctness.md includes all Standard correctness criteria plus:
  - Acceptance criteria validation against ticket (when ticket context available)
  - Deeper edge-case analysis with explicit escape hatch: if code handles edge cases adequately, state so — do not manufacture findings
  - Inaccurate naming elevated from minor to important severity (name implies different behavior than implementation)
- When this story is complete, the checklist includes ticket context instructions: use full ticket (minus verbose status update notes) when available; do not block on missing ticket context
- When this story is complete, build-review-agents.sh regenerates the deep correctness reviewer agent successfully

## Constraints
- Must reference Standard checklist criteria by inclusion, not duplication — the build process composes base + standard + deep-correctness

