---
id: w21-njch
status: open
deps: [w21-q0nn]
links: []
created: 2026-03-20T04:07:07Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-0k2k
---
# As a developer, I can detect and recover from ticket system corruption via fsck

## Description

**What**: Implement `ticket fsck` — validates system integrity, detects corruption, and reports issues. Non-destructive by default. Also harden the reducer to skip corrupt events with a warning.

**Why**: Crashes, disk errors, and interrupted compactions can leave the event store in an inconsistent state. fsck provides a recovery path.

**Scope**:
- IN: ticket fsck command, JSON validation, CREATE event verification, stale index.lock cleanup, SNAPSHOT consistency verification, reducer corruption resilience
- OUT: Automatic repair mode (future — fsck reports only in this story)

## Done Definitions

- When this story is complete, `ticket fsck` validates all event files parse as valid JSON and reports corrupt files
  ← Satisfies: "ticket fsck validates system integrity: all event files parse as valid JSON"
- When this story is complete, `ticket fsck` verifies every ticket has a CREATE event and flags tickets with missing or corrupt CREATE events
  ← Satisfies: "checks CREATE events"
- When this story is complete, `ticket fsck` detects and cleans stale `.git/index.lock` files (checks PID, removes if process is dead)
  ← Satisfies: "cleans stale .git/index.lock files"
- When this story is complete, `ticket fsck` verifies SNAPSHOT consistency: source_event_uuids don't reference events that still exist on disk, no orphaned pre-snapshot events exist, SNAPSHOT compiled state is internally consistent
  ← Satisfies: "SNAPSHOT source_event lists are consistent" + adversarial review — specific invariants
- When this story is complete, the reducer catches per-file JSON parse errors and skips corrupt events with a warning rather than failing the entire ticket
  ← Satisfies: "The reducer catches per-file JSON parse errors and skips corrupt events"
- When this story is complete, unit tests are written and passing for all new logic

## Considerations

- [Reliability] fsck must be non-destructive by default — report issues, don't fix them. Repair mode is a future enhancement
- [Reliability] Corrupt CREATE event interaction: w21-o72z flags these tickets as needing fsck repair. fsck should detect and report them with a clear recovery suggestion
