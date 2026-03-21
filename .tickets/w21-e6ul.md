---
id: w21-e6ul
status: open
deps: [w21-cjso, w21-0rql, w21-cbt4]
links: []
created: 2026-03-21T07:12:51Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-q0nn
---
# E2E: Full compaction flow — create, accumulate events, compact, verify SNAPSHOT and state

End-to-end test verifying the complete compaction flow including git commits, real flock, and ticket show output after compaction.

## Scope
- Creates a ticket with events exceeding the threshold using the real ticket CLI
- Runs 'ticket compact <ticket_id>'
- Verifies via 'ticket show <ticket_id>' that state is correct after compaction
- Verifies only SNAPSHOT event file remains (no original events)
- Verifies ticket show output matches pre-compaction state (same title, same status)

## TDD Requirement
This is a bash integration/E2E test. The test can be written after all implementation tasks complete.
Add to: tests/scripts/test-ticket-e2e.sh OR create tests/scripts/test-ticket-compact-e2e.sh
Run with: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact-e2e.sh

## Test: test_compact_e2e_full_flow

Setup in a temp git repo with ticket system initialized:
1. ticket create task 'Compaction E2E test'
2. Add 12 STATUS events (above default threshold of 10) via ticket-transition or direct event writes
3. Verify: ticket dir has 13 event files (1 CREATE + 12 STATUS)
4. Run: bash plugins/dso/scripts/ticket-compact.sh <ticket_id>
5. Verify exit 0
6. Verify: ticket dir has exactly 1 SNAPSHOT event file
7. Verify: ticket show <ticket_id> returns correct JSON with title='Compaction E2E test' and status matching final state
8. Verify: SNAPSHOT event file has source_event_uuids with 13 entries

## Test: test_compact_e2e_below_threshold_skips
1. Create ticket with 5 events (below threshold of 10)
2. Run: bash plugins/dso/scripts/ticket-compact.sh <ticket_id>
3. Verify: exit 0 with 'below threshold' message
4. Verify: original 5 event files still exist

## Test: test_compact_e2e_configurable_threshold
1. Set COMPACT_THRESHOLD=3
2. Create ticket with 4 events
3. Run compaction
4. Verify: compaction triggers (4 > 3) and SNAPSHOT created

## Note on E2E Exclusion from Standard Test Suite
E2E tests that require initializing a real git ticket system may be slow (>5s). If this test exceeds 10s, use the integration test exemption (exit 124 via record-test-exemption.sh pattern) or add to a separate slow-tests target.

## Files to Create/Edit
tests/scripts/test-ticket-compact-e2e.sh (new file)

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/scripts/test-ticket-compact-e2e.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-compact-e2e.sh
- [ ] Full E2E test passes: SNAPSHOT only, correct state, correct source_event_uuids count
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact-e2e.sh 2>&1 | grep -q 'PASS'
- [ ] Below-threshold test passes: original events preserved
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact-e2e.sh 2>&1 | grep -q 'below_threshold.*PASS'
- [ ] Configurable threshold test passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-compact-e2e.sh 2>&1 | grep -q 'configurable_threshold.*PASS'

