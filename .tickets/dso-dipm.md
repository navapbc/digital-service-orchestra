---
id: dso-dipm
status: open
deps: [dso-4cb7]
links: []
created: 2026-03-21T16:10:05Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-goqp
---
# RED: Extend test file with failing Bash variant tests for hook_tickets_tracker_bash_guard

TDD RED phase: Extend tests/hooks/test-tickets-tracker-guard.sh with failing tests for the Bash command variant.

Add tests for hook_tickets_tracker_bash_guard covering:
- Bash command containing .tickets-tracker/ reference blocks (returns exit 2)
  e.g.: 'echo foo > /repo/.tickets-tracker/event.json'
- Bash command that is a ticket CLI invocation allowlisted (returns exit 0)
  e.g.: 'ticket create ...' or 'tk show ...'
- Bash command with no .tickets-tracker/ reference allows (returns exit 0)
- Non-Bash tool type (Edit) returns exit 0 (not handled by bash guard)
- Empty command allows (fail-open, returns exit 0)

Append tests to the existing test file created in dso-yaao.
At this point hook_tickets_tracker_bash_guard does not exist - new tests must fail (RED).


## ACCEPTANCE CRITERIA

- [ ] Test file tests/hooks/test-tickets-tracker-guard.sh contains at least 8 assert_eq calls (5 original + 3+ bash variant)
  Verify: grep -c 'assert_eq' $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh | awk '{exit ($1 < 8)}'
- [ ] New bash variant tests fail RED (hook_tickets_tracker_bash_guard not yet defined)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh 2>&1; test $? -ne 0
- [ ] Edit/Write tests (from dso-4cb7) still pass (GREEN section unchanged)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-tickets-tracker-guard.sh 2>&1 | grep -c 'PASS' | awk '{exit ($1 < 5)}'
