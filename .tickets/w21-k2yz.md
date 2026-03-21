---
id: w21-k2yz
status: open
deps: []
links: []
created: 2026-03-20T05:07:23Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-54wx
---
# As a developer, I can track dependencies between tickets and query which are ready to work


## Notes

**2026-03-20T05:08:37Z**

## Description
**What**: LINK/UNLINK events for dependency relations (blocks, depends_on, relates_to). ticket deps command with ready_to_work. Cycle detection.
**Why**: Foundation for multi-agent orchestration — agents need to know which tickets are ready.
**Scope**:
- IN: ticket link, ticket unlink, cycle detection (dependency edges only, not hierarchy), ticket deps, graph cache, tombstone-awareness for archived tickets
- OUT: Auto-unblock (w21-8011), sync (w21-6k7v), archiving (w21-6llo)

## Done Definitions
- ticket link/unlink create LINK/UNLINK events ← Satisfies SC1
- ticket deps returns graph with ready_to_work boolean (direct blockers only) ← Satisfies SC2
- Cycle detection rejects circular dependencies (dependency edges only, not hierarchy) ← Satisfies SC1 + adversarial review
- Graph traversal <2s at 1,000 tickets (per-call SLA; burst callers batch/debounce) ← Satisfies SC9 + adversarial review
- Graph is tombstone-aware for archived tickets ← adversarial review
- Unit tests passing

## Considerations
- [Performance] Dense graphs need dedicated graph cache
- [Reliability] LINK events must survive compaction
- [Maintainability] Visited-set in traversal prevents infinite loops

**Escalation policy**: Proceed unless a significant assumption is required to continue. Escalate only when genuinely blocked. Document all assumptions.

**2026-03-21T16:05:31Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
