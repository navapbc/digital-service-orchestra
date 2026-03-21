---
id: dso-yaao
status: in_progress
deps: []
links: []
created: 2026-03-21T16:09:26Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-goqp
---
# RED: Write failing tests for hook_tickets_tracker_guard (Edit/Write blocking)

TDD RED phase: Write failing tests for the Edit/Write blocking guard before implementing it.

Create tests/hooks/test-tickets-tracker-guard.sh with tests covering:
- Edit targeting .tickets-tracker/ path blocks (returns exit 2)
- Write targeting .tickets-tracker/ path blocks (returns exit 2)
- Edit to non-.tickets-tracker/ path allows (returns exit 0)
- Bash tool type allows (not handled by Edit/Write guard, returns exit 0)
- Empty input allows (fail-open, returns exit 0)

Test structure follows tests/hooks/test-cascade-breaker.sh pattern:
source tests/lib/assert.sh, source pre-edit-write-functions.sh, use assert_eq.

At this point hook_tickets_tracker_guard does not exist - tests must fail (RED state).


## ACCEPTANCE CRITERIA

- [ ] Test file tests/hooks/test-tickets-tracker-guard.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh
- [ ] Test file contains at least 5 assert_eq calls
  Verify: grep -c 'assert_eq' $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh | awk '{exit ($1 < 5)}'
- [ ] Tests fail RED before hook implementation (hook_tickets_tracker_guard not yet defined)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh 2>&1; test $? -ne 0
- [ ] bash tests/run-all.sh passes (exit 0) — note: new test file will fail RED until Task 2 GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh

## Notes

<!-- note-id: q5s83s4p -->
<!-- timestamp: 2026-03-21T16:58:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 9my97vaz -->
<!-- timestamp: 2026-03-21T16:58:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — studied test-cascade-breaker.sh for test structure, pre-edit-write-functions.sh for hook contract, assert.sh for assertion helpers, run-hook-tests.sh for test discovery

<!-- note-id: d7r6u1j0 -->
<!-- timestamp: 2026-03-21T16:58:59Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — created tests/hooks/test-tickets-tracker-guard.sh with 5 assert_eq tests covering Edit/Write block, non-tracker path allow, Bash allow, empty input allow

<!-- note-id: zzro6xsk -->
<!-- timestamp: 2026-03-21T17:14:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — no implementation needed for RED phase; test file is the deliverable

<!-- note-id: tv4wra0b -->
<!-- timestamp: 2026-03-21T17:18:12Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — existing tests (cascade-breaker, deps) still pass; new test correctly fails RED (5/5 tests fail with exit 127, function not found)

<!-- note-id: bn4a628c -->
<!-- timestamp: 2026-03-21T17:18:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — AC1 PASS (file exists), AC2 PASS (5 assert_eq calls), AC3 PASS (tests fail RED exit 1), AC4 blocked until dso-4cb7 GREEN as noted in ticket
