---
id: dso-ru68
status: closed
deps: [dso-lcmz]
links: []
created: 2026-03-21T04:58:18Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Integration test: ticket list + transition + comment end-to-end workflow

Write an end-to-end integration test in tests/scripts/test-ticket-list-transition-comment-e2e.sh that exercises the full CRUD workflow using the ticket dispatcher.

File: tests/scripts/test-ticket-list-transition-comment-e2e.sh

Test scenario (single test function, executed in a temp git repo with ticket init):

1. Create two tickets via ticket create
2. Run ticket list → verify both tickets appear in JSON output with status='open'
3. Run ticket comment <id1> 'starting work' → verify exit 0
4. Run ticket transition <id1> open in_progress → verify exit 0
5. Run ticket list → verify id1 has status='in_progress', id2 still 'open'
6. Run ticket transition <id1> open closed (wrong current_status) → verify exit non-zero, output mentions actual status 'in_progress'
7. Run ticket transition <id1> in_progress closed → verify exit 0
8. Run ticket list → verify id1 has status='closed'
9. Run ticket comment <id1> 'done' → verify exit 0
10. Run ticket show <id1> → verify comments list contains both comments in order

Ghost prevention end-to-end:
11. Manually create a directory .tickets-tracker/ghost-xyz/ with no event files
12. Run ticket list → ghost-xyz appears with error status (not crash)
13. Run ticket transition ghost-xyz open in_progress → exits non-zero
14. Run ticket comment ghost-xyz 'test' → exits non-zero

This test serves as the E2E coverage for this story — the system has no browser frontend, so shell integration tests serve this purpose.

TDD Requirement: This test must pass (GREEN) after T10 (dso-lcmz) is complete and all three command scripts and dispatcher are wired.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-ticket-list-transition-comment-e2e.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list-transition-comment-e2e.sh
- [ ] Integration test passes end-to-end (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list-transition-comment-e2e.sh
- [ ] Integration test covers ghost prevention (transition + comment on ghost ticket exit non-zero)
  Verify: grep -q 'ghost\|no CREATE\|no event' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-list-transition-comment-e2e.sh

## Notes

<!-- note-id: pb8gs62n -->
<!-- timestamp: 2026-03-21T06:33:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: cex02l8k -->
<!-- timestamp: 2026-03-21T06:35:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: n21gxuds -->
<!-- timestamp: 2026-03-21T06:37:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-21T06:44:57Z**

CHECKPOINT 6/6: Done ✓ — E2E test. 34 passed, 0 failed.
