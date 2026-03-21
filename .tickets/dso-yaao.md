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
