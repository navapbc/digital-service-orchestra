---
id: dso-nj1w
status: closed
deps: [dso-vfj0, dso-of7g]
links: []
created: 2026-03-21T08:35:26Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-njch
---
# E2E test: ticket fsck full workflow validation

Write a bash E2E test that exercises the complete 'ticket fsck' workflow end-to-end using the 'ticket' dispatcher (not ticket-fsck.sh directly).

File: tests/scripts/test-ticket-fsck-e2e.sh (create new)
Alternative: extend tests/scripts/test-ticket-e2e.sh if the existing pattern fits

E2E scenarios to cover:
1. Happy path — initialize ticket system, create a valid ticket, run 'ticket fsck'; verify exits 0 and reports 'no issues found'
2. Corrupt event detection — after creating a ticket, overwrite one event file with invalid JSON, run 'ticket fsck'; verify exits non-zero and reports the corrupt file
3. Missing CREATE detection — manually create a ticket directory with only a STATUS event (no CREATE); run 'ticket fsck'; verify reports MISSING_CREATE
4. Stale lock cleanup — create a fake .tickets-tracker/.git/index.lock with a dead PID; run 'ticket fsck'; verify lock file is removed and exit 0 (no other issues)
5. SNAPSHOT consistency — create a ticket, compact it (ticket compact), then manually re-add one of the source event files; run 'ticket fsck'; verify SNAPSHOT_INCONSISTENT is reported

This E2E test uses the full 'ticket fsck' command (via dispatcher) against a real initialized git worktree. Use clone_test_repo from tests/lib/git-fixtures.sh.

TDD Requirement: This task depends on tasks dso-vfj0 (fsck implementation) and dso-of7g (dispatcher wiring) being complete. This test must PASS GREEN after those tasks are done.

Acceptance Criteria:
- [ ] test-ticket-fsck-e2e.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck-e2e.sh
- [ ] All 5 E2E scenarios pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck-e2e.sh
- [ ] Full test suite passes (run-all.sh includes new test)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] ruff check passes
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py


## Notes

<!-- note-id: g13py3n3 -->
<!-- timestamp: 2026-03-21T08:39:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded

<!-- note-id: 0z5tq8ca -->
<!-- timestamp: 2026-03-21T08:45:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done - 5 E2E tests written, all GREEN

**2026-03-21T09:05:35Z**

CHECKPOINT 6/6: Done ✓
