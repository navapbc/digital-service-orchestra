---
id: dso-n0fo
status: in_progress
deps: [dso-4uys]
links: []
created: 2026-03-22T03:54:27Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# RED: Write failing tests for REVERT check-before-overwrite in bridge-outbound.py

Write failing RED tests that define expected behavior for REVERT check-before-overwrite in bridge-outbound.py. All tests must FAIL before implementation.

File: tests/scripts/test_bridge_outbound_revert.py

Tests to write:

1. test_process_outbound_revert_fetches_jira_state_before_push
   - Create a ticket with CREATE + STATUS (closed) + REVERT (targeting STATUS event)
   - Provide mock acli_client with get_issue() returning current Jira state
   - Call process_outbound() with REVERT event in events list
   - Assert: acli_client.get_issue() was called with the ticket's jira_key BEFORE any update call

2. test_process_outbound_revert_emits_bridge_alert_when_jira_diverged
   - Set up ticket with REVERT event
   - Mock acli_client.get_issue() to return a different status than the original bad action's state (i.e., Jira has been changed since the REVERT target)
   - Call process_outbound()
   - Assert: a BRIDGE_ALERT event file is written to the ticket dir
   - Assert: BRIDGE_ALERT reason mentions 'diverged' or 'Jira state has changed'

3. test_process_outbound_revert_proceeds_when_jira_state_matches
   - Mock acli_client.get_issue() returning state matching expected pre-revert state
   - Call process_outbound()
   - Assert: no BRIDGE_ALERT written
   - Assert: acli_client.update_issue() or equivalent outbound push was called

4. test_process_outbound_revert_of_status_event_pushes_previous_status
   - Ticket has: STATUS(open→in_progress) + STATUS(in_progress→closed) [bad action] + REVERT targeting the 'closed' STATUS
   - Expected outbound effect: push status back to 'in_progress' (previous value before bad action)
   - Call process_outbound()
   - Assert: acli_client.update_issue() called with status='in_progress' (or Jira equivalent)

TDD Requirement: All tests must FAIL. Run: python3 -m pytest tests/scripts/test_bridge_outbound_revert.py -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/scripts/test_bridge_outbound_revert.py exists with at least 4 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound_revert.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound_revert.py | awk '{exit ($1 < 4)}'
- [ ] All 4 tests FAIL before bridge-outbound.py REVERT implementation (RED gate confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_revert.py -v 2>&1 | grep -qE 'FAILED|ERROR'

