---
id: w21-6llo
status: open
deps: [w21-k2yz, w21-6k7v]
links: []
created: 2026-03-20T05:07:35Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-54wx
---
# As a developer, I can archive closed tickets without breaking dependency references


## Notes

**2026-03-20T05:09:25Z**

## Description
**What**: ticket archive command for closed tickets. Protect tickets with open dependents or children. Tombstones for archived tickets. Sync-before-compact precondition.
**Why**: Without archiving, the event log grows without bound. Dependency-aware archiving prevents orphaned references.
**Scope**:
- IN: ticket archive, protection check (open dependents + children), tombstone file (ID, type, final status), sync-before-compact, skip tickets with remote SNAPSHOTs
- OUT: Automatic scheduled archiving (future enhancement)

## Done Definitions
- ticket archive removes closed tickets from active set ← Satisfies SC7
- Tickets with open dependents or open children are protected from archiving ← Satisfies SC7
- Archived tickets retain tombstone (ID, type, final status) queryable by dependency graph ← Satisfies SC7 + adversarial review
- Compaction syncs before compacting and skips tickets with remote SNAPSHOTs ← Satisfies SC7
- Unit tests passing

## Considerations
- [Reliability] Inbound LINK references from other tickets must resolve against tombstones, not fail
- [Reliability] sync-before-compact requires sync infrastructure (w21-6k7v) — dependency is set

**Escalation policy**: Proceed unless a significant assumption is required to continue. Escalate only when genuinely blocked. Document all assumptions.
