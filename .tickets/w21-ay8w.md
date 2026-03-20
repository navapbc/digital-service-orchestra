---
id: w21-ay8w
status: open
deps: [w21-f8tg]
links: []
created: 2026-03-20T04:07:08Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-0k2k
---
# As a developer, concurrent ticket sessions produce no data loss under stress

## Description

**What**: Build and run a concurrency stress test: 5 parallel sessions each performing 10 ticket operations. Verify all 50 events are preserved with correct content and distinct git commits.

**Why**: The entire architecture is designed for concurrent use. This story proves it works under realistic load, including with the cache layer active.

**Scope**:
- IN: Concurrency stress test harness, event count verification, content integrity verification, distinct commit verification, cache interaction under concurrent load
- OUT: Remote sync concurrency (Epic w21-54wx)

## Done Definitions

- When this story is complete, a stress test launches 5 parallel sessions each performing 10 ticket operations (mix of create, transition, comment)
  ← Satisfies: "Two concurrent sessions creating and modifying tickets produce no data loss"
- When this story is complete, all 50 events exist in the event log with correct JSON content, expected fields, and content matching the operation that created them
  ← Satisfies: "all events from both sessions are preserved and correctly attributed in separate git commits"
- When this story is complete, each event is in a distinct git commit with correct attribution (not bundled with another session's events via git add -A)
  ← Satisfies: "correctly attributed in separate git commits"
- When this story is complete, the stress test exercises the cache layer (Story w21-f8tg) — concurrent cache invalidation and rebuild produces correct results
  ← Satisfies: adversarial review — concurrent cache rebuild race tested
- When this story is complete, unit tests are written and passing for all new logic

## Considerations

- [Testing] Stress test must be deterministic and not flaky — use process-level parallelism (not threads) with synchronized start
- [Testing] Test must validate event content integrity, not just count — each event file must parse as valid JSON and match its operation
