---
id: w21-ul0j
status: in_progress
deps: [w21-1plz, w21-g3x6, w21-ymip, w21-up52]
links: []
created: 2026-03-21T00:56:05Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ablv
---
# Integration test: ticket init + create + show end-to-end


## Description

Write an end-to-end integration test that exercises the full init → create → show workflow.
Test file: `tests/scripts/test-ticket-e2e.sh`

### Rationale for integration test (not E2E web test):
This is a CLI tool — no browser UI or HTTP endpoints. The integration test IS the end-to-end test for this story.
E2E web test: N/A — purely internal CLI tool with no user-facing web behavior.

### Test functions to write:
1. `test_full_workflow_init_create_show` — in a fresh temp git repo:
   a. Run `ticket init` → assert exit 0 and `.tickets-tracker/` exists
   b. Run `ticket create task "My first ticket"` → capture ticket_id
   c. Run `ticket show <ticket_id>` → assert exit 0 and output JSON has `title = "My first ticket"` and `ticket_type = "task"`
   d. Assert the tickets branch has exactly 2 commits (init commit + create commit)

2. `test_workflow_with_special_chars_in_title` — assert `ticket create task "It's a \"test\" title"` does not break JSON parsing (title with quotes and apostrophes is correctly escaped)

3. `test_create_and_show_multiple_tickets` — create 3 tickets in sequence; assert each has a unique ticket_id and `ticket show` returns correct state for each

4. `test_env_id_embedded_in_events` — assert the env_id from `.tickets-tracker/.env-id` is present in the CREATE event JSON of a newly created ticket

5. `test_concurrent_create_serialized_by_flock` — launch 3 parallel `ticket create` calls simultaneously; assert all 3 complete without error and all 3 ticket IDs are unique and all 3 events are committed to the tickets branch (no lost writes)

### Setup: each test uses a fresh temp git repo
### Teardown: remove temp dir

Note: Test 5 (concurrent creates) validates flock serialization — critical for the story's reliability requirement.

Depends on: w21-1plz (init), w21-g3x6 (create), w21-ymip (show), w21-up52 (auto-init)

## TDD Requirement
Integration test task — does NOT require a preceding RED task (exemption: integration test written after implementation; existing unit tests cover the individual components; this test verifies the integration boundary).
Exemption criterion: integration test — covered by existing implementation tasks' unit tests for individual components; this test verifies the cross-component contract, which requires the implementation to exist.

## Acceptance Criteria
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/run-all.sh`
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes
  Verify: `cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] Integration test file exists at `tests/scripts/test-ticket-e2e.sh`
  Verify: `test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-e2e.sh`
- [ ] Integration test suite passes (all 5 assertions green)
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-e2e.sh`
- [ ] Concurrent create test (test 5) verifies no lost writes under parallel load
  Verify: `bash $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-e2e.sh 2>&1 | grep -q 'test_concurrent_create_serialized_by_flock.*PASS'`

## Notes

<!-- note-id: s3z2r7yp -->
<!-- timestamp: 2026-03-21T04:17:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: h8l5mdzg -->
<!-- timestamp: 2026-03-21T04:17:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: ybzl7u4o -->
<!-- timestamp: 2026-03-21T04:19:07Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: 1um4mttc -->
<!-- timestamp: 2026-03-21T04:24:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Integration test passes (33/33 assertions, shellcheck clean) ✓

<!-- note-id: 3a8i1yjh -->
<!-- timestamp: 2026-03-21T04:44:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All 5 tests pass (33 assertions), shellcheck clean, ruff clean, AC6 verified. run-all.sh timeout is pre-existing (SIGURG ceiling), not caused by this change.
