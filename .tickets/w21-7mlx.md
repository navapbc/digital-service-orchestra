---
id: w21-7mlx
status: open
deps: [w21-2a9w]
links: []
created: 2026-03-20T17:23:47Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, all existing tickets are migrated to the new system preserving IDs, data, and relationships


## Notes

**2026-03-20T17:24:24Z**

## Description
**What**: Pre-flight snapshot + data migration. Capture full tk show output per ticket, counts, dep graph, Jira mappings. Migrate all .tickets/*.md to event files using new ticket CLI commands. Preserve old ticket IDs.
**Why**: Data migration is the foundation — everything depends on accurate, complete ticket data in the new system.
**Scope**:
- IN: Pre-flight comprehensive snapshot, migration via ticket CLI commands (create, transition, comment, link), preserve old IDs as primary key, idempotent (skip already-migrated), malformed ticket handling (log + skip), disable compaction during migration, notes with timestamps preserved
- OUT: Reference update (w21-wbqz), validation comparison (w21-25mq), cleanup (w21-gy45)

## Done Definitions
- Pre-flight snapshot captures full tk show output for every ticket, counts, dep graph, Jira mappings ← Satisfies SC2
- Migration converts all .tickets/*.md to event files preserving IDs, status, deps, parent/child, notes, Jira keys ← Satisfies SC3
- Migration uses new ticket CLI commands (self-tests the new system) ← Satisfies SC3
- Migration is idempotent — skips already-migrated tickets on re-run ← Satisfies SC1
- Compaction disabled during migration ← SC3 (data integrity)
- Unit tests passing

## Considerations
- [Reliability] Old ticket IDs preserved as event directory names — cross-epic dep on dso-0k2k flexible ID validation
- [Reliability] Malformed frontmatter logged and skipped, not crash
- [Reliability] Notes with special characters go through Python json.dumps

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. High confidence means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
