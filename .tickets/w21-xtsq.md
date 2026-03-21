---
id: w21-xtsq
status: open
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
