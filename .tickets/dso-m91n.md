---
id: dso-m91n
status: closed
deps: [dso-22iz, dso-wz2l, dso-rqj9, dso-els2, dso-yyll]
links: []
created: 2026-03-22T03:54:57Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# E2E test: bridge observability and recovery full flow

Write an end-to-end test covering the full bridge observability and recovery flow from BRIDGE_ALERT emission through health warning display to REVERT and fsck.

File: tests/scripts/test_bridge_observability_e2e.sh (bash E2E test)

Test scenario:
1. Initialize a ticket tracker (ticket init)
2. Create a test ticket (ticket create)
3. Simulate a bridge failure: write a BRIDGE_ALERT event directly to the ticket dir
4. Run 'ticket show <id>' — assert: stderr or JSON output contains bridge_alerts with 1 unresolved entry
5. Run 'ticket list' — assert: output for the ticket includes bridge_alerts entry
6. Write a .bridge-status.json with last_run_timestamp, success=false, error='test_error', unresolved_conflicts=1
7. Run 'ticket bridge-status' — assert: output mentions failure and test_error
8. Run 'ticket bridge-fsck' — assert: exit 0 when no mapping issues, or correctly reports issues
9. Write a STATUS event + a REVERT event targeting the STATUS event
10. Run reduce_ticket() (via ticket show) — assert: reverts list has 1 entry
11. Run 'ticket revert <id> <bad_status_uuid>' — assert: new REVERT event file created

This E2E test validates the complete developer workflow end-to-end.

TDD Requirement: This task depends on all implementation tasks completing. It is a post-implementation validation E2E test, not a RED-first test (integration test rule: may be written after implementation).

Run: bash tests/scripts/test_bridge_observability_e2e.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] E2E test file tests/scripts/test_bridge_observability_e2e.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_observability_e2e.sh
- [ ] E2E test passes end-to-end (all 11 steps)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test_bridge_observability_e2e.sh
- [ ] ticket show displays bridge_alerts in JSON output
  Verify: bash tests/scripts/test_bridge_observability_e2e.sh 2>&1 | grep -q 'bridge_alerts'
- [ ] ticket bridge-status shows last run info
  Verify: bash tests/scripts/test_bridge_observability_e2e.sh 2>&1 | grep -qi 'last_run\|bridge-status'
- [ ] ticket bridge-fsck reports clean when no mapping issues
  Verify: bash tests/scripts/test_bridge_observability_e2e.sh 2>&1 | grep -qi 'bridge-fsck\|no issues'
- [ ] ticket revert creates REVERT event file
  Verify: bash tests/scripts/test_bridge_observability_e2e.sh 2>&1 | grep -qi 'REVERT\|revert'


## Notes

**2026-03-22T06:13:08Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T06:13:49Z**

CHECKPOINT 2/6: Code patterns understood ✓ - Scripts use TICKETS_TRACKER_DIR env var for test isolation; ticket init creates .tickets-tracker/ in test repos; tests use clone_test_repo + assert.sh + git-fixtures.sh pattern

**2026-03-22T06:15:00Z**

CHECKPOINT 3/6: Tests written ✓ - Created tests/scripts/test-bridge-observability-e2e.sh with 11-step E2E scenario covering BRIDGE_ALERT injection, ticket show/list warnings, bridge-status, bridge-fsck, REVERT injection, and ticket revert CLI

**2026-03-22T06:16:07Z**

CHECKPOINT 4/6: Implementation complete ✓ - Test passes 23/23 assertions covering all 11 E2E steps

**2026-03-22T06:16:15Z**

CHECKPOINT 5/6: Lint passed ✓ - ruff check and ruff format --check both pass clean

**2026-03-22T06:19:35Z**

CHECKPOINT 6/6: Done ✓ - All AC checks pass: test file executable, 23/23 assertions pass, bridge_alerts/bridge-status/bridge-fsck/REVERT keywords all in output, ruff lint clean, full test suite green
