---
id: dso-smgw
status: in_progress
deps: []
links: []
created: 2026-03-21T08:34:07Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-njch
---
# RED: Write failing tests for ticket-fsck.sh validation checks

Write a RED test suite for the ticket-fsck.sh command that does not yet exist.

File: tests/scripts/test-ticket-fsck.sh (create new)

Tests to write (all must fail RED until ticket-fsck.sh is implemented):
1. test_fsck_detects_corrupt_json_event — create a ticket dir with a non-JSON event file; verify fsck reports it as corrupt
2. test_fsck_detects_missing_create_event — create a ticket dir with STATUS event but no CREATE; verify fsck flags the ticket
3. test_fsck_detects_stale_index_lock — create a fake .tickets-tracker/.git/index.lock with a dead PID; verify fsck removes it and reports
4. test_fsck_detects_live_index_lock — create a fake .tickets-tracker/.git/index.lock with a live PID (own shell's PID); verify fsck reports it but does NOT remove it
5. test_fsck_reports_snapshot_orphaned_source_uuid — create a SNAPSHOT whose source_event_uuids references a UUID that still exists as an event file on disk; verify fsck flags the inconsistency
6. test_fsck_reports_snapshot_missing_source_uuid — create a SNAPSHOT whose source_event_uuids references a UUID for an event that no longer exists AND there is no post-snapshot event with that UUID (orphaned pre-snapshot event was deleted correctly — this should PASS; test the inverse: if source_event_uuids references a UUID that does still exist on disk, that's the problem)
7. test_fsck_exits_zero_on_clean_system — initialize a clean ticket system, create a valid ticket; verify fsck exits 0 and reports no issues
8. test_fsck_is_nondestructive_on_valid_events — run fsck on valid events; verify no files are modified

TDD Requirement: All tests must FAIL (RED) before ticket-fsck.sh exists. Include suite-runner guard (see test-ticket-compact.sh pattern) that skips with exit 0 when ticket-fsck.sh absent and _RUN_ALL_ACTIVE=1.

Use the test helpers from tests/lib/assert.sh and tests/lib/git-fixtures.sh (clone_test_repo).

Acceptance Criteria:
- [ ] test-ticket-fsck.sh exists at tests/scripts/test-ticket-fsck.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck.sh
- [ ] Test file is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck.sh
- [ ] Test file contains at least 7 test functions
  Verify: grep -c 'test_fsck_' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck.sh | awk '{exit ($1 < 7)}'
- [ ] Running the test suite exits non-zero (RED — script not yet implemented)
  Verify: { bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-fsck.sh 2>&1; test $? -ne 0; }
- [ ] ruff format-check passes on this file (no Python here; bash lint via shellcheck is optional)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py

## GAP ANALYSIS AMENDMENT (dso-smgw)

Test assertions must use the exact output format strings defined in dso-vfj0 (the implementation task):
- Corrupt JSON: assert output contains 'CORRUPT: <ticket_id>/<filename>'
- Missing CREATE: assert output contains 'MISSING_CREATE: <ticket_id>'
- Stale lock removed: assert output contains 'FIXED: removed stale .git/index.lock'
- Live lock: assert output contains 'WARN: .git/index.lock held by live process'
- Snapshot inconsistency: assert output contains 'SNAPSHOT_INCONSISTENT:'
- Clean system: assert output contains 'fsck complete: no issues found'

These strings must match exactly between test assertions (dso-smgw) and implementation (dso-vfj0). If dso-vfj0's output strings change during implementation, update test assertions accordingly before marking this task complete.


## Notes

<!-- note-id: 6ypn3xum -->
<!-- timestamp: 2026-03-21T08:39:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded

<!-- note-id: xajkrdrp -->
<!-- timestamp: 2026-03-21T08:40:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done - 8 RED tests written, all failing
