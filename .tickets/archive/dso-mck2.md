---
id: dso-mck2
status: closed
deps: []
links: []
created: 2026-03-22T03:54:29Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-fj1t
---
# Write failing tests for .test-index RED marker parsing in record-test-status.sh

Write failing tests (RED phase) in tests/hooks/test-record-test-status.sh that verify the new RED marker behavior. These tests must fail before the implementation in the next task exists.

## TDD Requirement

Write these 5 test functions FIRST. All 5 must fail (non-zero exit from their assertions) before the implementation task is done. Use the existing create_test_repo helper pattern and RECORD_TEST_STATUS_RUNNER mock for pytest-unavailable environments.

Test functions to add:
- test_red_marker_tolerates_failure_after_marker: When .test-index entry has [test_red_function] and the test file has failing tests at/after test_red_function, record-test-status.sh exits 0 and writes 'passed' to test-gate-status
- test_red_marker_blocks_failure_before_marker: When .test-index entry has [test_red_function] and a test BEFORE test_red_function fails, record-test-status.sh exits 1 and writes 'failed'
- test_no_marker_backward_compat: When .test-index entry has no marker (existing format), behavior is identical to current — failures always block
- test_marker_not_found_falls_back_to_blocking: When the marker name in [brackets] does not match any function in the test file, record-test-status.sh warns to stderr and exits 1 (blocking, not silent tolerance)
- test_red_zone_bash_test_file: RED marker detection works for bash test files (function/marker patterns), not only Python

## Files
- tests/hooks/test-record-test-status.sh — edit (append new test functions)

## Test Filename Fuzzy Match
Source: plugins/dso/hooks/record-test-status.sh — normalized: recordteststatussh
Test: tests/hooks/test-record-test-status.sh — normalized: testrecordteststatussh
recordteststatussh IS a substring of testrecordteststatussh — auto-detected, no .test-index entry needed.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py
- [ ] Test file contains all 5 new test functions
  Verify: grep -c 'test_red_marker_tolerates_failure_after_marker\|test_red_marker_blocks_failure_before_marker\|test_no_marker_backward_compat\|test_marker_not_found_falls_back_to_blocking\|test_red_zone_bash_test_file' $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh | awk '{exit ($1 < 5)}'
- [ ] All 5 new test functions fail pre-implementation (RED phase — verify manually before implementation task)
  Verify: # Manually confirm assertions fail before implementation exists (RED gate)
- [ ] Test file remains executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/hooks/test-record-test-status.sh


## Notes

<!-- note-id: h43xx9p1 -->
<!-- timestamp: 2026-03-22T03:58:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 28lr1lhq -->
<!-- timestamp: 2026-03-22T03:59:37Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: wql08s4w -->
<!-- timestamp: 2026-03-22T04:00:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: a05cp5a9 -->
<!-- timestamp: 2026-03-22T04:00:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ (no implementation needed — this is a test-writing task)

<!-- note-id: qyhw1i6q -->
<!-- timestamp: 2026-03-22T04:13:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 5 new tests fail as expected (RED phase: PASSED 27 FAILED 5)

<!-- note-id: pcrs2hm8 -->
<!-- timestamp: 2026-03-22T04:13:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — all 5 AC checks pass; 5 new RED tests fail as expected; 27 existing tests pass

**2026-03-22T04:18:06Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/hooks/test-record-test-status.sh. Tests: 27 passed, 5 RED tests fail as expected.
