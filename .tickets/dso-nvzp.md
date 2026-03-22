---
id: dso-nvzp
status: open
deps: [dso-qwrw]
links: []
created: 2026-03-22T03:52:34Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# RED: Write failing tests for ticket bridge-status command

Write failing RED tests that define the expected behavior for 'ticket bridge-status'. These tests must FAIL before implementation and PASS after.

File: tests/scripts/test_ticket_bridge_status.sh (bash test)
OR tests/scripts/test_bridge_status.py (python test, preferred for fixture control)

Tests to write:

1. test_bridge_status_shows_last_run_time
   - Create a .tickets-tracker/.bridge-status.json fixture with last_run_timestamp, success=true
   - Run: ticket bridge-status
   - Assert: output contains last_run_timestamp value

2. test_bridge_status_shows_failure_when_last_run_failed
   - Create fixture with success=false, error='auth_failure'
   - Run: ticket bridge-status
   - Assert: output contains 'failure' or 'failed' and the error reason

3. test_bridge_status_shows_unresolved_conflicts
   - Create fixture with unresolved_conflicts count > 0
   - Run: ticket bridge-status
   - Assert: output contains unresolved conflict count

4. test_bridge_status_exits_nonzero_when_no_status_file
   - Remove .bridge-status.json fixture
   - Run: ticket bridge-status
   - Assert: exit non-zero OR outputs 'no bridge status file found' message

5. test_bridge_status_json_output_format
   - Create fixture
   - Run: ticket bridge-status --format=json
   - Assert: output is valid JSON with keys: last_run_timestamp, success, error, unresolved_conflicts

TDD Requirement: All tests must FAIL before implementation. Run: bash tests/scripts/test_bridge_status.py or bash tests/scripts/test_ticket_bridge_status.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/scripts/test_bridge_status.py exists with at least 5 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_status.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_status.py | awk '{exit ($1 < 5)}'
- [ ] All 5 tests FAIL before ticket-bridge-status.sh implementation (RED gate confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_status.py -v 2>&1 | grep -qE 'FAILED|ERROR'

