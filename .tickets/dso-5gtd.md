---
id: dso-5gtd
status: in_progress
deps: [dso-qwrw]
links: []
created: 2026-03-22T03:53:01Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# RED: Write failing tests for ticket bridge-fsck command

Write failing RED tests that define expected behavior for 'ticket bridge-fsck'. These tests must FAIL before implementation and PASS after.

File: tests/scripts/test_bridge_fsck.py

This is a BRIDGE-SPECIFIC fsck (mapping audit, orphans, duplicates, stale SYNC events) — distinct from the existing ticket-fsck.sh (JSON validity + CREATE presence + index.lock cleanup).

Tests to write:

1. test_bridge_fsck_detects_orphaned_ticket
   - Create a ticket with a SYNC event mapping to jira_key 'DSO-99'
   - Omit any corresponding local mapping
   - Run: ticket bridge-fsck
   - Assert: output contains 'orphan' or 'orphaned' and 'DSO-99'

2. test_bridge_fsck_detects_duplicate_jira_mapping
   - Create two tickets both with SYNC events mapping to same jira_key
   - Run: ticket bridge-fsck
   - Assert: output contains 'duplicate' and the repeated jira_key

3. test_bridge_fsck_detects_stale_sync_events
   - Create a ticket with a SYNC event but no BRIDGE_ALERT or subsequent activity for >30 days
   - Run: ticket bridge-fsck
   - Assert: output contains 'stale' or 'stale_sync'

4. test_bridge_fsck_clean_output_when_no_issues
   - Create a clean ticket with valid SYNC mapping
   - Run: ticket bridge-fsck
   - Assert: exit 0 and output contains 'no issues found' or similar

5. test_bridge_fsck_exit_code
   - With issues present: assert exit non-zero
   - With no issues: assert exit 0

TDD Requirement: All tests must FAIL before implementation. Run: python3 -m pytest tests/scripts/test_bridge_fsck.py -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/scripts/test_bridge_fsck.py exists with at least 5 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_fsck.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_fsck.py | awk '{exit ($1 < 5)}'
- [ ] All 5 tests FAIL before ticket-bridge-fsck.py implementation (RED gate confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_fsck.py -v 2>&1 | grep -qE 'FAILED|ERROR'
- [ ] Tests cover: orphan detection, duplicate mapping, stale SYNC, clean output, exit code
  Verify: grep -qE 'test_bridge_fsck_detects_orphaned|test_bridge_fsck_detects_duplicate|test_bridge_fsck_detects_stale|test_bridge_fsck_clean_output|test_bridge_fsck_exit_code' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_fsck.py

