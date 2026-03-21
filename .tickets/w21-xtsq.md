---
id: w21-xtsq
status: in_progress
deps: [w21-mtvm]
links: []
created: 2026-03-21T00:52:38Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# RED: Write failing test test_write_commit_event_atomic_flock


## Description

Write failing shell tests for the shared `write_commit_event` helper in `ticket-lib.sh`.
Test file: `tests/scripts/test-ticket-lib.sh`

### Test functions to write (all must FAIL before implementation):
1. `test_write_commit_event_writes_atomic_file` — assert that calling `write_commit_event <ticket_id> <event_json_path>`:
   - The final event JSON file exists at `.tickets-tracker/<ticket-id>/<timestamp>-<uuid>-CREATE.json`
   - No partial/temp file remains in `.tickets-tracker/<ticket-id>/` after completion
   - The written JSON is valid (parseable by `python3 -c "import json,sys; json.load(sys.stdin)"`)
2. `test_write_commit_event_uses_flock` — assert that the helper acquires and releases the flock lock file at the expected path (`.tickets-tracker/.ticket-write.lock`)
3. `test_write_commit_event_commits_specific_file` — assert that after writing, `git -C .tickets-tracker log --name-only -1` shows only the specific event file was staged (not git add -A)
4. `test_write_commit_event_sets_gc_auto_zero` — assert that git config gc.auto is 0 in the tickets worktree
5. `test_write_commit_event_fails_cleanly_if_no_init` — assert that calling the helper without a prior `ticket init` exits non-zero with an error message

### Test setup pattern:
- Each test creates a temp git repo, runs `ticket init`, then invokes `write_commit_event` directly (source ticket-lib.sh)
- Tests assert on filesystem state and git log output

## TDD Requirement
RED: All test functions listed above must return non-zero (FAIL) before `ticket-lib.sh` is implemented.
Verify RED: `bash tests/scripts/test-ticket-lib.sh 2>&1; test $? -ne 0`

## Acceptance Criteria
- [ ] `bash tests/run-all.sh` passes (exit 0) — existing tests still green; new test is RED
  Verify: `bash $(git rev-parse --show-toplevel)/tests/run-all.sh`
- [ ] Test file exists at `tests/scripts/test-ticket-lib.sh`
  Verify: `test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh`
- [ ] Test file contains at least 5 test functions
  Verify: `grep -c 'test_write_commit_event' $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh | awk '{exit ($1 < 5)}'`
- [ ] Running the new test returns non-zero (RED)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-lib.sh 2>&1; test $? -ne 0`

## Notes

<!-- note-id: 7wqju7sy -->
<!-- timestamp: 2026-03-21T02:00:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: ftk33rsr -->
<!-- timestamp: 2026-03-21T02:01:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — ticket-lib.sh does not exist, ticket dispatcher at plugins/dso/scripts/ticket, tests use assert.sh + git-fixtures.sh, test files auto-discovered by run-script-tests.sh pattern test-*.sh

<!-- note-id: pnwhdyuo -->
<!-- timestamp: 2026-03-21T02:02:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — 5 test functions in tests/scripts/test-ticket-lib.sh covering atomic write, flock, specific-file commit, gc.auto=0, and clean failure without init

<!-- note-id: j21wvnuc -->
<!-- timestamp: 2026-03-21T02:02:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete (RED test only) ✓ — no ticket-lib.sh implementation written; tests are RED by design

<!-- note-id: 53kwuula -->
<!-- timestamp: 2026-03-21T02:02:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation complete ✓ — test exits non-zero (5 FAILs, 0 PASSes) confirming RED state; shellcheck passes with exit 0

<!-- note-id: qlln4u5a -->
<!-- timestamp: 2026-03-21T02:03:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All ACs satisfied: file exists at tests/scripts/test-ticket-lib.sh; 5 test functions (10 grep matches); exits non-zero (5 FAILs, 0 PASSes = RED); shellcheck clean; existing test-ticket-init.sh still passes (14 pass, 0 fail)
