---
id: dso-t561
status: in_progress
deps: [dso-mso2]
links: []
created: 2026-03-21T04:57:18Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# RED: Write failing tests for ticket-transition.sh (optimistic concurrency + ghost prevention)

Write failing tests (RED) in tests/scripts/test-ticket-transition.sh. All tests must FAIL before ticket-transition.sh exists.

File: tests/scripts/test-ticket-transition.sh

Test cases:
1. Happy path: ticket transition <id> open in_progress → exits 0, STATUS event written with correct status
2. Optimistic concurrency rejection: transition <id> open closed when actual status is in_progress → exits non-zero, prints actual status, NO STATUS event written
3. Ghost prevention: transition on a ticket_id with no ticket dir → exits non-zero with clear error
4. Ghost prevention: transition on a ticket dir with no CREATE event → exits non-zero with clear error
5. Idempotent no-op: transition <id> open open (current=target) → exits 0 with a message that no transition occurred (or exits 0 silently), NO new STATUS event written
6. Invalid target_status: transition <id> open invalid_status → exits non-zero with error about invalid status
7. Concurrent safety: two transitions attempted on the same ticket → at most one succeeds; no corrupt event files

Implementation pattern:
- Tests use a minimal fixture: ticket init in temp repo + ticket create to create a test ticket
- Tests call bash plugins/dso/scripts/ticket transition <id> <current> <target>

TDD Requirement: All tests must fail (exit non-zero) before ticket-transition.sh is implemented.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-ticket-transition.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-transition.sh
- [ ] test-ticket-transition.sh contains at least 7 test cases
  Verify: grep -c 'PASS\|FAIL\|assert\|test_' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-transition.sh | awk '{exit ($1 < 7)}'
- [ ] All tests in test-ticket-transition.sh fail (RED) before ticket-transition.sh is created
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-transition.sh 2>&1; test $? -ne 0

## Notes

<!-- note-id: r95cw34m -->
<!-- timestamp: 2026-03-21T05:38:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 6lzv291h -->
<!-- timestamp: 2026-03-21T05:38:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: uqf1p0zr -->
<!-- timestamp: 2026-03-21T05:40:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: ke02hn7y -->
<!-- timestamp: 2026-03-21T05:40:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: RED test only (no implementation) ✓

<!-- note-id: it9isryc -->
<!-- timestamp: 2026-03-21T05:40:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation complete — RED (exit 1, PASSED: 0 FAILED: 7) + shellcheck passes ✓

<!-- note-id: h1ebyhby -->
<!-- timestamp: 2026-03-21T05:40:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
