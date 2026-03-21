---
id: dso-quie
status: in_progress
deps: []
links: []
created: 2026-03-21T08:34:25Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-njch
---
# RED: Write failing tests for reducer corrupt-event skip behavior

Extend tests/scripts/test_ticket_reducer.py with RED tests for the reducer's corrupt-event skipping behavior.

File: tests/scripts/test_ticket_reducer.py (edit existing)

Tests to add (verify the reducer skips corrupt mid-sequence events and still returns valid state):
1. test_reducer_skips_corrupt_json_event_and_returns_valid_state — create a ticket dir with a valid CREATE event, a corrupt .json file (invalid JSON), and a valid COMMENT event; verify reducer returns state with the comment (corrupt file skipped, not a fatal error)
2. test_reducer_emits_warning_for_corrupt_event — same setup; capture stderr; verify a WARNING message is printed mentioning the corrupt file path
3. test_reducer_skips_corrupt_event_in_snapshot_pass1 — create ticket with CREATE + corrupt event + SNAPSHOT; verify reducer uses the SNAPSHOT state (corrupt event skipped gracefully during pass 1 snapshot scan)
4. test_reducer_all_events_corrupt_returns_error_dict — create ticket dir with only corrupt .json files (no parseable events); verify returns dict with status='error' and ticket_id set (ghost ticket prevention already implemented — ensure test covers this code path explicitly)

TDD Requirement: Run existing tests to confirm they pass first. New tests must be isolated (use tmp_path fixture). These tests verify behavior already implemented in ticket-reducer.py — they will PASS (GREEN) once written IF the implementation is correct. If any test fails RED, that indicates a reducer bug to fix before proceeding to task 3.

Acceptance Criteria:
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] New test functions exist in test_ticket_reducer.py
  Verify: grep -c 'def test_reducer_skips_corrupt' $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py | awk '{exit ($1 < 2)}'
- [ ] All new tests pass (GREEN — behavior already implemented in reducer)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py -k 'corrupt' --tb=short -q
- [ ] Existing reducer tests still pass
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_ticket_reducer.py --tb=short -q


## Notes

<!-- note-id: 73p9yhy5 -->
<!-- timestamp: 2026-03-21T08:39:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded

<!-- note-id: bv2he6j1 -->
<!-- timestamp: 2026-03-21T08:42:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done - 4 corrupt-event tests added, all GREEN
