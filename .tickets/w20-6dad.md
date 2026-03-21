---
id: w20-6dad
status: closed
deps: []
links: []
created: 2026-03-21T16:32:26Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# RED test: sync-before-compact precondition in ticket-compact.sh

TDD RED phase for sync-before-compact. Write failing tests in tests/scripts/test-compact-sync-precondition.sh asserting that ticket-compact.sh calls ticket sync before compacting when sync is available. Tests: (1) test_compact_calls_sync_before_compacting — verify compact invokes sync subcommand (intercept via PATH shim or TICKET_SYNC_CMD env override); sync must be called before any SNAPSHOT is written, (2) test_compact_skips_ticket_with_remote_snapshot — when a remote SNAPSHOT event exists (simulated via a SNAPSHOT file committed to a remote branch), compaction must skip the ticket with exit 0 and a skip message, (3) test_compact_sync_failure_aborts_compact — if sync returns non-zero, compact must abort with non-zero exit and not create SNAPSHOT, (4) test_compact_proceeds_if_no_remote_snapshot — no remote SNAPSHOT; compact proceeds normally after sync. Include suite-runner guard. Tests MUST FAIL (RED) against current ticket-compact.sh (which has no sync call).

## ACCEPTANCE CRITERIA

- [ ] Test file exists at tests/scripts/test-compact-sync-precondition.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh
- [ ] Test file contains at least 4 test functions matching test_compact_
  Verify: grep -c 'test_compact_' $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh | awk '{exit ($1 < 4)}'
- [ ] Tests fail RED without implementation (script exits non-zero when guard disabled)
  Verify: _RUN_ALL_ACTIVE=0 bash $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh 2>/dev/null; test $? -ne 0
- [ ] bash tests/run-all.sh passes exit 0 (suite-runner guard suppresses RED tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] Test 5 covers graceful behavior when ticket sync subcommand is absent (w21-6k7v not yet merged)
  Verify: grep -q 'sync.*absent\|no.*sync.*subcommand\|sync_subcommand_missing\|sync.*not.*available' $(git rev-parse --show-toplevel)/tests/scripts/test-compact-sync-precondition.sh

