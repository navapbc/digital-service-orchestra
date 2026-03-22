---
id: dso-7n6c
status: in_progress
deps: [dso-qwrw]
links: []
created: 2026-03-22T03:51:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# RED: Write failing tests for BRIDGE_ALERT detection in ticket-reducer.py and ticket-show.sh/ticket-list.sh

Write failing RED tests that define the expected behavior for BRIDGE_ALERT detection. These tests must FAIL before implementation and PASS after.

File: tests/scripts/test_bridge_alert_display.py

Tests to write:

1. test_reducer_detects_unresolved_bridge_alert
   - Create a ticket dir with a CREATE event + a BRIDGE_ALERT event
   - Assert reduce_ticket() returns state with 'bridge_alerts' list containing 1 entry
   - Assert entry has: reason, timestamp, uuid, resolved=False

2. test_reducer_alert_resolved_by_resolution_event
   - Create ticket with CREATE + BRIDGE_ALERT + another BRIDGE_ALERT with data.resolved=True referencing alert UUID
   - Assert reduce_ticket() returns state with 'bridge_alerts' where the original alert has resolved=True (or is absent from unresolved list)

3. test_reducer_no_alerts_when_none_present
   - Create ticket with only CREATE event
   - Assert reduce_ticket() returns state with 'bridge_alerts' == [] or key absent

4. test_ticket_show_outputs_health_warning_when_unresolved_alerts
   - Create a ticket dir with BRIDGE_ALERT event
   - Run ticket-show.sh for that ticket
   - Assert output contains 'BRIDGE_ALERT' or '⚠' or 'bridge_alert' in the JSON bridge_alerts field

5. test_ticket_list_includes_bridge_alerts_in_output
   - Create ticket with BRIDGE_ALERT
   - Run ticket-list.sh
   - Assert the ticket entry in output has non-empty bridge_alerts list

TDD Requirement: All tests must return FAIL (AssertionError or ImportError) before the implementation task runs.
Run: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py -v 2>&1

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/scripts/test_bridge_alert_display.py exists with at least 5 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_alert_display.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_alert_display.py | awk '{exit ($1 < 5)}'
- [ ] All 5 tests FAIL before reducer implementation (RED gate confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py -v 2>&1 | grep -qE 'FAILED|ERROR'
- [ ] Tests cover: unresolved alert detection, alert resolution, no-alert case, ticket-show warning, ticket-list inclusion
  Verify: grep -qE 'test_reducer_detects_unresolved|test_reducer_alert_resolved|test_reducer_no_alerts|test_ticket_show_outputs|test_ticket_list_includes' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_alert_display.py

