---
id: w21-ukq9
status: in_progress
deps: [w21-1plz, w21-g3x6, w21-6bmd, w21-ymip]
links: []
created: 2026-03-21T00:56:54Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ablv
---
# ADR: Event-sourced ticket storage on orphan branch architecture decision


## Description

Create an Architecture Decision Record documenting the event-sourced ticket storage design approved in Step 2 of implementation planning (architectural review).

**Location**: `plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md`
(Following the existing design docs convention: `plugins/dso/docs/designs/`)

### ADR sections to cover:
1. **Context**: Current tk system uses mutable .tickets/ markdown files — causes merge conflicts, data loss on concurrent writes, performance degradation with ticket count
2. **Decision**: Event-sourced append-only storage on a git orphan branch, mounted as `.tickets-tracker/` worktree
3. **Consequences**:
   - Positive: No merge conflicts (append-only); concurrent writes serialized by flock; python3 reducer is testable in isolation; gc.auto=0 prevents lock contention during Claude timeouts
   - Negative: All reads require reducer compilation (mitigated by caching in w21-f8tg); orphan branch adds one git operation per write
4. **Alternatives considered**: Direct .tickets/ mutation (rejected: merge conflicts), SQLite database (rejected: binary file, not git-friendly), separate git repo (rejected: too much operational overhead)
5. **Implementation**: Points to this story (w21-ablv) and related stories (w21-o72z, w21-f8tg, w21-q0nn)
6. **Cross-story contracts**: References `plugins/dso/docs/contracts/ticket-event-format.md` and `plugins/dso/docs/contracts/ticket-flock-contract.md`

### Style guide:
Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting conventions if available.

Depends on: w21-1plz, w21-g3x6, w21-6bmd, w21-ymip (ADR documents the implemented system)

## TDD Requirement
test-exempt: documentation artifact — no conditional logic, no executable code.
Exemption criterion: "static assets only — no executable assertion is possible."

## Acceptance Criteria
- [ ] ADR file exists at `plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md`
  Verify: `test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md`
- [ ] ADR references the flock contract document
  Verify: `grep -q 'ticket-flock-contract\|flock' $(git rev-parse --show-toplevel)/plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md`
- [ ] ADR references the event format contract document
  Verify: `grep -q 'ticket-event-format\|event.*format' $(git rev-parse --show-toplevel)/plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md`
- [ ] ADR covers consequences (both positive and negative)
  Verify: `grep -qi 'consequence\|positive\|negative\|tradeoff' $(git rev-parse --show-toplevel)/plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md`

## Notes

**2026-03-21T04:08:06Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T04:08:42Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T04:08:43Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-21T04:09:56Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T04:10:05Z**

CHECKPOINT 5/6: Validation passed ✓ — all 4 ACs pass (file exists, flock contract referenced, event-format contract referenced, consequences covered)

**2026-03-21T04:10:07Z**

CHECKPOINT 6/6: Self-check AC complete ✓ — ADR covers all required sections: context, decision, consequences (positive + negative), alternatives considered, implementation story table, cross-story contracts
