---
id: w21-q0nn
status: open
deps: [w21-f8tg]
links: []
created: 2026-03-20T04:07:05Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-0k2k
---
# As a developer, ticket performance stays stable over time via event compaction

## Description

**What**: Implement event compaction: when a ticket exceeds a configurable event threshold, squash its history into a single SNAPSHOT event. Delete original events. Include source_event_uuids for idempotent replay after rebase.

**Why**: Without compaction, the event log grows without bound. A ticket with 50 status transitions means 50+ files to read on every show/list. Compaction keeps read performance stable.

**Scope**:
- IN: SNAPSHOT event type, compaction trigger logic, flock during entire compaction, specific-file deletion, source_event_uuids, reducer SNAPSHOT handling, cache interaction verification
- OUT: Dependency-aware archiving (Epic w21-54wx), remote sync interactions (Epic w21-54wx)

## Done Definitions

- When this story is complete, compaction triggers when a ticket exceeds a configurable event count threshold and produces a single SNAPSHOT event containing the compiled state plus source_event_uuids
  ← Satisfies: "Event compaction squashes a ticket's event history into a single SNAPSHOT event"
- When this story is complete, compaction holds flock for the entire operation (read events, write SNAPSHOT, delete originals) and deletes only the specific files read into the snapshot
  ← Satisfies: "Compaction holds flock for the entire operation"
- When this story is complete, the reducer handles SNAPSHOT + post-snapshot events correctly, skipping duplicates whose UUID appears in source_event_uuids
  ← Satisfies: "SNAPSHOT includes a source_event_uuids field so the reducer can skip duplicate events"
- When this story is complete, the compiled-state cache returns correct state after compaction (warm cache before compaction produces correct results after compaction runs)
  ← Satisfies: adversarial review — cache-compaction interaction verified from compaction side
- When this story is complete, unit tests are written and passing for all new logic

## Considerations

- [Reliability] Compaction race condition is the most critical risk — events written between snapshot compile and deletion must not be lost. flock entire operation + specific-file deletion prevents this
- [Reliability] Cache invalidation must detect compaction (file count and listing change). Verify the cache layer (w21-f8tg) handles this correctly
