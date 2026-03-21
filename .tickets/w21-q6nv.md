---
id: w21-q6nv
status: in_progress
deps: []
links: []
created: 2026-03-21T07:10:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-q0nn
---
# RED: Write failing tests for ticket-compact.sh compaction script

Write failing bash tests for the ticket-compact.sh script that does not yet exist.

## TDD Requirement
All tests MUST fail (RED) before ticket-compact.sh is created. Confirm failure with:
  cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | tail -20
Expected: all tests fail (script not found or subcommand not available).

## New Test File: tests/scripts/test-ticket-compact.sh

Follow the pattern of tests/scripts/test-ticket-lib.sh (setup git repo fixture, use BATS or bash assert pattern).

### test_compact_triggers_when_threshold_exceeded
- Initialize ticket system in a temp repo
- Create a ticket and add events until count > COMPACT_THRESHOLD (default 10)
- Run: bash ticket-compact.sh <ticket_id>
- Assert: ticket dir contains exactly 1 SNAPSHOT event file and 0 original event files

### test_compact_does_not_trigger_below_threshold
- Create a ticket with fewer events than threshold
- Run: bash ticket-compact.sh <ticket_id>
- Assert: exit 0 with message 'below threshold — skipping'; original events still exist

### test_compact_snapshot_contains_source_event_uuids
- Create a ticket with 3 events (above threshold 2 for test)
- Run compaction with COMPACT_THRESHOLD=2
- Assert: SNAPSHOT event JSON has source_event_uuids list with 3 UUIDs (one per original event)

### test_compact_deletes_only_specific_files_read_into_snapshot
- Create ticket dir with events e1, e2, e3
- Start compaction in background; just before rename-and-delete, write event e4 (simulate race)
- After compaction, assert e4 still exists (only e1, e2, e3 were in scope of snapshot)
  (Simplification: verify source_event_uuids does not include e4's uuid — direct file check)

### test_compact_flock_prevents_concurrent_modification
- Create two concurrent compact runs on same ticket
- Assert only one SNAPSHOT is written (second run fails or waits for first to finish)

### test_compact_produces_valid_snapshot_event_json
- Create ticket with events above threshold
- Run compaction
- Assert: SNAPSHOT event file parses as valid JSON with required fields:
  event_type='SNAPSHOT', data.compiled_state (non-null dict), data.source_event_uuids (list), timestamp, uuid, env_id, author

### test_compact_subcommand_routes_correctly
- Run: bash ticket compact <ticket_id>
- Assert: exit 0 (dispatcher routes to ticket-compact.sh)

## File to Create
tests/scripts/test-ticket-compact.sh

## Dependencies
None — RED tests always written before implementation.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-ticket-compact.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-compact.sh
- [ ] Test file contains at least 6 test cases
  Verify: grep -c 'assert\|FAIL\|PASS\|it_\|test_' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-compact.sh | awk '{exit ($1 < 6)}'
- [ ] All tests in test-ticket-compact.sh FAIL before implementation (RED gate)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact.sh 2>&1 | grep -q 'FAIL\|not found\|No such'
- [ ] Test file includes test case for corrupt/ghost ticket (reducer exits 1) — compact.sh must error clearly
  Verify: grep -q 'corrupt_ticket\|ghost_ticket' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-compact.sh


## Notes

**2026-03-21T07:16:16Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T07:20:04Z**

CHECKPOINT 6/6: Done ✓
