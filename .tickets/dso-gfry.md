---
id: dso-gfry
status: open
deps: [dso-bxng]
links: []
created: 2026-03-21T23:20:12Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-ovpn
---
# As a DSO practitioner, the Deep Sonnet B reviewer applies deep verification checks evaluating test quality and coverage


## Notes

<!-- note-id: 5t4zz04f -->
<!-- timestamp: 2026-03-21T23:21:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create the reviewer-delta-deep-verification.md checklist for the Deep tier Sonnet B (verification specialist) reviewer.

**Why**: Deep tier reviews high-complexity changes. Sonnet B owns verification — evaluating whether the test suite is trustworthy and covers the right behaviors. It does not identify edge cases itself; it evaluates test coverage of edge cases present in the code.

## Acceptance Criteria

- When this story is complete, reviewer-delta-deep-verification.md includes all Standard verification criteria plus:
  - Test as documentation: can someone read the test and understand the intended behavior?
  - Test isolation evaluation: are tests independent or do they depend on shared state/execution order?
- When this story is complete, the checklist explicitly states: does not identify edge cases — evaluates whether test suite covers edge cases present in the code
- When this story is complete, the checklist includes no ticket context instructions (verification is code-observable)
- When this story is complete, build-review-agents.sh regenerates the deep verification reviewer agent successfully

## Scope Boundary
- This story owns checklist criteria for how the reviewer evaluates test quality in the diff
- dso-ppwp owns pre-commit test gate enforcement that blocks commits when tests haven't been run

