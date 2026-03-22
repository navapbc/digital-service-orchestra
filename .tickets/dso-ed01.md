---
id: dso-ed01
status: closed
deps: [dso-4uys]
links: []
created: 2026-03-22T03:53:32Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# RED: Write failing tests for REVERT event writing, CLI validation, and reducer handling

Write failing RED tests that define expected behavior for REVERT events. All tests must FAIL before implementation.

File: tests/scripts/test_revert_event.py

Tests to write:

1. test_ticket_revert_writes_revert_event
   - Create a ticket with a CREATE and STATUS event
   - Run: ticket revert <ticket_id> <target_event_uuid> --reason='test reason'
   - Assert: a REVERT event file exists in .tickets-tracker/<ticket_id>/
   - Assert: REVERT event has event_type='REVERT', data.target_event_uuid=<target_event_uuid>, data.target_event_type='STATUS', data.reason='test reason'

2. test_ticket_revert_rejects_revert_of_revert
   - Create a ticket with CREATE + STATUS + REVERT event
   - Run: ticket revert <ticket_id> <revert_event_uuid>
   - Assert: exit non-zero
   - Assert: stderr contains 'cannot revert a REVERT event'

3. test_ticket_revert_rejects_nonexistent_target
   - Run: ticket revert <ticket_id> 'nonexistent-uuid'
   - Assert: exit non-zero
   - Assert: stderr contains 'event not found' or 'no event with UUID'

4. test_reducer_records_reverts_in_compiled_state
   - Create ticket with CREATE + STATUS + REVERT (targeting STATUS uuid)
   - Call reduce_ticket()
   - Assert: state['reverts'] is a list with 1 entry
   - Assert: entry has target_event_uuid matching the STATUS event uuid, target_event_type='STATUS'

5. test_reducer_revert_does_not_undo_status_automatically
   - Create ticket with CREATE + STATUS (closed) + REVERT (targeting STATUS)
   - Call reduce_ticket()
   - Assert: state['status'] is still 'closed' (undo is NOT automatic — only bridge-outbound handles the outbound effect)
   - Assert: state['reverts'] has 1 entry

TDD Requirement: All must FAIL before implementation. Run: python3 -m pytest tests/scripts/test_revert_event.py -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/scripts/test_revert_event.py exists with at least 5 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_revert_event.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_revert_event.py | awk '{exit ($1 < 5)}'
- [ ] All 5 tests FAIL before ticket-revert.sh implementation (RED gate confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py -v 2>&1 | grep -qE 'FAILED|ERROR'
- [ ] Tests cover: REVERT event writing, REVERT-of-REVERT rejection, nonexistent target rejection, reducer reverts list, status not auto-undone
  Verify: grep -qE 'test_ticket_revert_writes|test_ticket_revert_rejects_revert_of|test_ticket_revert_rejects_nonexistent|test_reducer_records_reverts|test_reducer_revert_does_not_undo' $(git rev-parse --show-toplevel)/tests/scripts/test_revert_event.py

