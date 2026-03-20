---
id: w21-f8tg
status: open
deps: [w21-o72z]
links: []
created: 2026-03-20T04:07:05Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-0k2k
---
# As a developer, I experience fast ticket reads via compiled-state caching

## Description

**What**: Add a compiled-state cache that stores the reducer's output. Content-hash invalidation (hash of directory listing, not mtime). Atomic cache writes. Idempotent concurrent recompilation.

**Why**: Without caching, every `ticket show` and `ticket list` re-reads all event files. At 1,000 tickets this takes seconds. Caching makes warm reads near-instant.

**Scope**:
- IN: Cache file storage, content-hash invalidation, atomic cache writes, idempotent recompilation, performance target validation
- OUT: Compaction (w21-q0nn) — but cache invalidation must survive file deletion (see considerations)

## Done Definitions

- When this story is complete, the reducer uses a file-based compiled-state cache with content-hash invalidation based on directory listing hash
  ← Satisfies: "python3 reducer uses a file-based compiled-state cache with content-hash invalidation"
- When this story is complete, cache writes are atomic (temp file + rename) and concurrent recompilation produces identical results
  ← Satisfies: "cache writes are atomic and concurrent recompilation is idempotent"
- When this story is complete, all CRUD operations complete in under 500ms with 200 tickets and under 2 seconds with 1,000 tickets on a warm cache
  ← Satisfies: "All CRUD operations complete in under 500ms with 200 tickets"
- When this story is complete, cache invalidation correctly detects when event files are added OR deleted from a ticket directory (not just additions)
  ← Satisfies: adversarial review — cache must survive compaction's file deletions in w21-q0nn
- When this story is complete, unit tests are written and passing for all new logic

## Considerations

- [Performance] Content hash (directory listing hash) must be cheaper than the cache rebuild it prevents — benchmark at 1,000 tickets
- [Reliability] Cache invalidation must handle file deletion (not just addition). Story w21-q0nn will delete event files during compaction — the cache must detect this as a change. Design the invalidation to be deletion-aware from the start
