---
id: dso-0k2k
status: closed
deps: []
links: []
created: 2026-03-17T18:34:29Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-36
---
# Ticket system upgrade

We have a collection of documents that describe an update to our ticketing system. We should rename our script because we have significantly diverged from tk. The update involves using an orphan branch and an event log to more effectively manage real time sync between worktrees on the same environment and near-realtime sync between sessions across environments. Our main pain points are conflicts merging and committing tickets, lack of awareness between simultaneous sessions, and data loss due to improper overwrites of tickets by other sessions. Our secondary concern is performance. The system must be able to comfortably handle 1000 open tickets as a max without running into exit code 144 timeouts (~73 second command time, but we should have a comfortable buffer to account for hooks).


## Notes

**2026-03-20T03:28:13Z**

## Context
The current tk ticket system stores mutable markdown files in .tickets/, causing merge conflicts when multiple worktrees or sessions modify tickets concurrently. Data loss occurs when one session overwrites another's changes, and performance degrades with ticket count because every operation parses individual files. A new event-sourced storage engine on a git orphan branch eliminates these problems: append-only event files cannot conflict, serialized git commits prevent index corruption, a python3 reducer with compiled-state caching handles reads efficiently, and event compaction keeps performance stable as the event log grows. The system runs parallel to tk until cutover (Epic 4).

## Success Criteria
1. ticket init creates an orphan tickets branch and mounts it as .tickets-tracker/ via git worktree add, adds .tickets-tracker to both .git/info/exclude and the committed .gitignore
2. ticket create, ticket show, ticket list, ticket transition, and ticket comment work correctly using append-only event files and a python3 reducer that compiles events to current state
3. All JSON construction and parsing goes through Python (json.dumps/json.load) — never bash string interpolation or heredocs. All file I/O uses explicit encoding='utf-8'. All timestamps are UTC epoch seconds
4. Git commits are serialized via flock with timeout and retry. Each write command uses git add <specific-file> (not git add -A) to prevent staging other sessions event files. gc.auto is set to 0 on the tickets worktree to prevent garbage collection from holding the lock during Claude's timeout ceiling
5. Event file writes use atomic temp-file-then-rename to prevent truncated JSON from disk-full or process kills. The reducer catches per-file JSON parse errors and skips corrupt events with a warning rather than failing the entire operation
6. The python3 reducer uses a file-based compiled-state cache with content-hash invalidation (hash of directory listing, not mtime) — cache writes are atomic and concurrent recompilation is idempotent
7. Event compaction squashes a ticket's event history into a single SNAPSHOT event when event count exceeds a configurable threshold. Compaction holds flock for the entire operation (read events, write snapshot, delete originals). Only the specific files read into the snapshot are deleted. The SNAPSHOT includes a source_event_uuids field so the reducer can skip duplicate events after compaction + rebase
8. Non-CREATE write commands verify the target ticket directory exists and contains a CREATE event before proceeding — prevents ghost tickets from typos
9. ticket fsck validates system integrity: all event files parse as valid JSON, all tickets have a CREATE event, no stale .git/index.lock files, SNAPSHOT source_event lists are consistent
10. All CRUD operations complete in under 500ms with 200 tickets (typical load) and under 2 seconds with 1,000 tickets (peak load), measured end-to-end including reducer compilation on a warm cache
11. Two concurrent sessions creating and modifying tickets produce no data loss — all events from both sessions are preserved and correctly attributed in separate git commits. Validated by: a concurrency stress test that launches 5 parallel sessions each performing 10 ticket operations, then verifies all 50 events exist in the event log with correct content and distinct git commits

## Dependencies
None

## Approach
Event-sourced storage on a git orphan branch. Python3 for all JSON I/O. flock-serialized git commits with specific-file staging. Content-hash cache invalidation. SNAPSHOT-based compaction with source_event_uuids for idempotent replay.

## Design References
See plugins/dso/docs/ticket-migraiton-v3/ for the 7 design documents informing this architecture.

## Red Team / Blue Team Review
Architecture reviewed via adversarial red-team (16 findings) and independent blue-team validation. All CRITICAL and HIGH findings incorporated into success criteria above. See conversation history for full findings.

**2026-03-20T04:25:14Z**

## Additional Success Criteria (added during Epic 2 brainstorm)

12. Every ticket command auto-initializes if .tickets-tracker/ does not exist — ticket init runs silently on first use, making initialization transparent to the session/user
13. ticket init generates a unique environment ID (UUID) at .tickets-tracker/.env-id (gitignored on the tickets branch) that is embedded in every event for cross-environment conflict resolution

**2026-03-20T04:58:15Z**

## Additional Success Criterion (timeout hardening)

14. No single ticket operation holds flock for more than 10 seconds. flock acquisition timeout is 30 seconds per attempt with max 2 retries. Total worst-case wall time for any ticket command stays under 60 seconds, preserving a safe margin from the 73-second Claude tool timeout ceiling. If flock cannot be acquired within the timeout budget, the command fails with a clear error rather than hanging.

**2026-03-20T04:58:45Z**

## Additional Success Criterion (compaction safety for sync)

15. SNAPSHOT events include a compacted_at timestamp (UTC epoch) in addition to source_event_uuids. The reducer skips events for a ticket whose timestamps are less than or equal to compacted_at, handling the case where remote events with old timestamps arrive after local compaction.

**2026-03-20T17:17:09Z**

## Cross-Epic Dependency (from w21-24kl migration epic)

16. The ticket system's ID validation must accept old-format ticket IDs (e.g., dso-0k2k, w21-54wx) for migrated tickets — not restricted to TKT-xxxxxxxx format. The migration preserves old IDs to avoid breaking all cross-references in descriptions, deps, parent fields, CLAUDE.md, and skill files.
